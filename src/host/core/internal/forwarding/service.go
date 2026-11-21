package forwarding

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/francoisnt/jailbox/internal/buildversion"
	"github.com/francoisnt/jailbox/internal/forwardproto"
	"golang.org/x/sys/unix"
)

const maxRequests = 32
const terminationGrace = 350 * time.Millisecond

func helper(operation string, args ...string) (*exec.Cmd, error) {
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	command := exec.Command(self, append([]string{buildversion.Version, operation}, args...)...)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	command.Stderr = os.Stderr
	return command, nil
}

func start(state, generation, config, host string, rawMounts []byte) error {
	if !generationID.MatchString(generation) {
		return errors.New("invalid forwarding container identity")
	}
	if err := inspectState(state); err != nil {
		return err
	}
	saved, err := loadManifest()
	if err != nil {
		return err
	}
	if err := saved.checkMounts(rawMounts); err != nil {
		return err
	}
	lock, idle, err := lockState(true)
	if err != nil {
		return err
	}
	defer lock.Close()
	if !idle {
		return errors.New("host forwarding service state already exists")
	}
	for _, name := range []string{controlSocket, requestSocket} {
		if _, err := os.Lstat(name); !os.IsNotExist(err) {
			return errors.New("host forwarding service state already exists")
		}
	}
	log, err := os.OpenFile(logFile, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	command, err := helper("serve", generation, config, host)
	if err != nil {
		return err
	}
	// ExtraFiles start at descriptor 3, where serve expects the lock.
	command.ExtraFiles = []*os.File{lock}
	command.Stderr = log
	if err := command.Start(); err != nil {
		return err
	}
	return command.Process.Release()
}

// Every child leads its own process group. Its group ID is its process ID,
// which stays reserved until the child is reaped. A group signal is safe only
// while the child is unreaped, so reaping and group signals share a lock.
type child struct {
	process *os.Process
	done    chan struct{}
	reap    sync.Mutex
}

func startChild(command *exec.Cmd) (*child, error) {
	if err := command.Start(); err != nil {
		return nil, err
	}
	child := &child{process: command.Process, done: make(chan struct{})}
	go func() { child.finish(command, awaitExit(child.process.Pid)) }()
	return child, nil
}

// finish reaps the child once awaitExit returns. If its exit could not be
// observed, the child may still be running and a later group signal would
// be unsafe, so its group is killed now, while the child is still unreaped.
func (child *child) finish(command *exec.Cmd, watchErr error) {
	child.reap.Lock()
	defer child.reap.Unlock()
	if watchErr != nil {
		// The signal is sent before the leader is reaped, while the process
		// group ID is still reserved, so it cannot reach an unrelated group.
		unix.Kill(-child.process.Pid, unix.SIGKILL)
	}
	command.Wait()
	close(child.done)
}

// killGroup kills the child's whole process group, so a forwarded command
// cannot outlive an unresponsive worker. It never signals a group after the
// child was reaped, when another process could have reused the group ID.
// It reports whether the child is done: it already exited, or the group
// signal was delivered or found no members. A child that exited counts as
// done, as during the grace period: workers stop their own group on SIGTERM.
func (child *child) killGroup() bool {
	child.reap.Lock()
	defer child.reap.Unlock()
	select {
	case <-child.done:
		return true
	default:
	}
	err := unix.Kill(-child.process.Pid, unix.SIGKILL)
	return err == nil || err == unix.ESRCH
}

func stopChildren(children map[*child]bool) error {
	var result error
	for child := range children {
		if err := child.process.Signal(syscall.SIGTERM); err != nil && !errors.Is(err, os.ErrProcessDone) {
			result = errors.Join(result, err)
		}
	}
	if waitChildren(children, terminationGrace+600*time.Millisecond) {
		return result
	}
	groupsKilled := true
	for child := range children {
		if !child.killGroup() {
			groupsKilled = false
		}
		// Process.Kill tracks child identity even if Wait just reaped it.
		child.process.Kill()
	}
	// Report success only once every child is reaped and its group was killed.
	if waitChildren(children, time.Second) && groupsKilled {
		return result
	}
	return errors.Join(result, errors.New("could not verify shutdown of all host forwarding processes"))
}

// waitChildren reports whether every child was reaped within the timeout.
func waitChildren(children map[*child]bool, timeout time.Duration) bool {
	deadline := time.After(timeout)
	for child := range children {
		select {
		case <-child.done:
		case <-deadline:
			return false
		}
	}
	return true
}

func listen(path string) (*net.UnixListener, error) {
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, err
	}
	// Retirement owns deletion after it obtains the lock.
	listener.SetUnlinkOnClose(false)
	return listener, nil
}

type incoming struct {
	conn *net.UnixConn
	err  error
}

func acceptConnections(ctx context.Context, listener *net.UnixListener) <-chan incoming {
	ch := make(chan incoming)
	go func() {
		for {
			conn, err := listener.AcceptUnix()
			select {
			case ch <- incoming{conn, err}:
			case <-ctx.Done():
				if conn != nil {
					conn.Close()
				}
				return
			}
			if err != nil {
				return
			}
		}
	}()
	return ch
}

func serve(generation, config, host string) error {
	// start passed the owned lock as descriptor 3 and already entered the
	// state directory.
	unix.CloseOnExec(3)
	defer unix.Close(3)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	saved, err := loadManifest()
	if err != nil {
		return err
	}
	control, err := listen(controlSocket)
	if err != nil {
		return err
	}
	defer control.Close()
	requests, err := listen(requestSocket)
	if err != nil {
		return err
	}
	defer requests.Close()
	lifetimeRead, lifetimeWrite, err := os.Pipe()
	if err != nil {
		return err
	}
	defer lifetimeRead.Close()
	defer lifetimeWrite.Close()
	sshCommand := exec.Command(string(saved.SSH), "-F", config, "-T", "-o", "ExitOnForwardFailure=yes",
		"-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
		"-o", "ControlMaster=no", "-o", "ForwardAgent=no",
		"-R", forwardproto.Socket+":./"+requestSocket, host,
		forwardproto.ContainerHelper+" "+buildversion.Version+" hold")
	sshCommand.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	sshCommand.Stderr = os.Stderr
	hold, err := sshCommand.StdinPipe()
	if err != nil {
		return err
	}
	defer hold.Close()
	ssh, err := startChild(sshCommand)
	if err != nil {
		return err
	}

	workers := make(map[*child]bool)
	controls := acceptConnections(ctx, control)
	calls := acceptConnections(ctx, requests)
	var retireReply *net.UnixConn
loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case <-ssh.done:
			break loop
		case event := <-controls:
			if event.err != nil {
				err = event.err
				break loop
			}
			if handleControl(event.conn, ssh, generation) {
				retireReply = event.conn
				break loop
			}
			event.conn.Close()
		case event := <-calls:
			if event.err != nil {
				err = event.err
				break loop
			}
			// Wait is owned by each child's goroutine. Only the service
			// loop adds or removes children from this set.
			for worker := range workers {
				select {
				case <-worker.done:
					delete(workers, worker)
				default:
				}
			}
			refusal := "service busy or stopping"
			if len(workers) < maxRequests {
				// A request that cannot start, for example when the host is out of
				// file descriptors, is refused alone. The service keeps running.
				worker, startErr := startRequest(event.conn, lifetimeRead, generation)
				if startErr == nil {
					workers[worker] = true
					refusal = ""
				} else {
					fmt.Fprintln(os.Stderr, "Error:", startErr)
					refusal = "could not start the forwarded request"
				}
			}
			if refusal != "" {
				event.conn.SetWriteDeadline(time.Now().Add(50 * time.Millisecond))
				forwardproto.Send(event.conn, 'F', []byte(refusal))
			}
			event.conn.Close()
		}
	}

	cancel()
	control.Close()
	requests.Close()
	lifetimeWrite.Close()
	hold.Close()
	workers[ssh] = true
	shutdownErr := stopChildren(workers)
	if retireReply != nil {
		defer retireReply.Close()
		retireReply.SetWriteDeadline(time.Now().Add(time.Second))
		if shutdownErr != nil {
			forwardproto.Send(retireReply, 'F', []byte(shutdownErr.Error()))
		} else {
			forwardproto.Send(retireReply, 'S', nil)
		}
	}
	if shutdownErr != nil {
		// Exiting releases the state lock, which lets retirement delete the
		// state. Hold it until every child is confirmed gone, however long.
		for child := range workers {
			<-child.done
		}
	}
	return errors.Join(err, shutdownErr)
}

func handleControl(conn *net.UnixConn, ssh *child, generation string) bool {
	conn.SetDeadline(time.Now().Add(200 * time.Millisecond))
	kind, _, err := forwardproto.Receive(conn, 0)
	if err != nil {
		return false
	}
	switch kind {
	case 'S':
		return true
	case 'H':
		select {
		case <-ssh.done:
		default:
			forwardproto.Send(conn, 'H', []byte(generation))
		}
	}
	return false
}

func startRequest(conn *net.UnixConn, lifetime *os.File, generation string) (*child, error) {
	connection, err := conn.File()
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	command, err := helper("request", generation)
	if err != nil {
		return nil, err
	}
	// ExtraFiles start at descriptor 3, where request expects the connection,
	// followed by the lifetime pipe at 4.
	command.ExtraFiles = []*os.File{connection, lifetime}
	child, err := startChild(command)
	if err != nil {
		return nil, fmt.Errorf("could not start forwarding request: %w", err)
	}
	return child, nil
}
