package forwardclient

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
)

func Run(operation string, args []string) int {
	status, err := run(operation, args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
	}
	return status
}

func run(operation string, args []string) (int, error) {
	if operation == "probe" {
		if len(args) != 1 {
			return 1, errors.New("expected a readiness challenge")
		}
		if err := probe(args[0]); err != nil {
			return 1, err
		}
		return 0, nil
	}
	if len(args) == 0 || args[0] == "" {
		return 1, errors.New("expected a forwarded command")
	}
	cwd, err := syscall.Getwd()
	if err != nil {
		return 1, err
	}
	var relative string
	if cwd != forwardproto.Project {
		var inside bool
		relative, inside = strings.CutPrefix(cwd, forwardproto.Project+"/")
		if !inside {
			return local(args, "outside the sandbox project")
		}
	}
	frame, err := argv.Encode("forwarded command", args)
	if err != nil {
		return 1, err
	}
	if len(relative) > forwardproto.DirectoryLimit {
		return 1, errors.New("forwarded working directory is too long")
	}
	conn, err := net.Dial("unix", forwardproto.Socket)
	if err != nil {
		return 1, errors.New("service unavailable. Run 'jailbox stop' then 'jailbox up'")
	}
	status, err := forward(conn, relative, frame)
	var fallback *localFallback
	if errors.As(err, &fallback) {
		return local(args, fallback.reason)
	}
	return status, err
}

const wrapperDir = "/run/jailbox-sshd/host-commands"

// Search the original PATH in order, omitting the forwarding wrapper even
// when its directory has another spelling or a symlink points at it.
func localPath(name, path, cwd string) (string, error) {
	wrapper, _ := os.Stat(filepath.Join(wrapperDir, name))
	for _, dir := range strings.Split(path, string(os.PathListSeparator)) {
		if !filepath.IsAbs(dir) {
			dir = cwd + "/" + dir
		}
		candidate := dir + "/" + name
		info, err := os.Stat(candidate)
		if err != nil || (wrapper != nil && os.SameFile(info, wrapper)) {
			continue
		}
		if file, err := exec.LookPath(candidate); err == nil {
			return file, nil
		}
	}
	return "", fmt.Errorf("local executable %s is unavailable", name)
}

func local(args []string, reason string) (int, error) {
	cwd, err := syscall.Getwd()
	if err == nil {
		var path string
		if search, ok := os.LookupEnv("PATH"); ok {
			path, err = localPath(args[0], search, cwd)
		} else {
			err = fmt.Errorf("local executable %s is unavailable (PATH is unset)", args[0])
		}
		if err == nil {
			err = syscall.Exec(path, args, os.Environ())
		}
	}
	return 125, fmt.Errorf("host command forwarding: %s; %w", reason, err)
}

type localFallback struct{ reason string }

func (f *localFallback) Error() string { return f.reason }

type signalExit struct{ name string }

func (e *signalExit) Error() string { return "host command terminated by " + e.name }

type sender func(byte, []byte) error

func forward(conn net.Conn, relative, frame string) (int, error) {
	defer conn.Close()
	var started atomic.Bool
	var lock sync.Mutex
	send := func(kind byte, data []byte) error {
		lock.Lock()
		defer lock.Unlock()
		return forwardproto.Send(conn, kind, data)
	}
	signals := make(chan os.Signal, 16)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	finished := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case sig := <-signals:
				if !started.Load() {
					fmt.Fprintln(os.Stderr, "Error: host command forwarding interrupted. Command outcome is unknown.")
					terminate(sig.(syscall.Signal))
					os.Exit(125)
				}
				if err := send('G', []byte(forwardproto.SignalName(sig.(syscall.Signal)))); err != nil {
					conn.Close()
					return
				}
			case <-finished:
				return
			}
		}
	}()
	status, err := streamRequest(conn, relative, frame, os.Stdin, os.Stdout, os.Stderr, send, func() {
		started.Store(true)
		if terminal(os.Stdout) && terminal(os.Stderr) {
			fmt.Fprintln(os.Stderr, "[HOST]")
		}
	})
	signal.Stop(signals)
	close(finished)
	conn.Close() // unblock a signal write before waiting for the goroutine
	<-done
	var exit *signalExit
	if errors.As(err, &exit) {
		sig := forwardproto.SignalNumber(exit.name)
		if sig == 0 {
			return 125, fmt.Errorf("host termination signal %s has no local equivalent", exit.name)
		}
		terminate(sig)
		return 125, fmt.Errorf("could not reproduce host termination by %s", exit.name)
	}
	var fallback *localFallback
	if errors.As(err, &fallback) {
		return status, err
	}
	if err != nil {
		return 1, errors.New("host command forwarding connection interrupted. Command outcome is unknown.")
	}
	return status, nil
}

func probe(challenge string) error {
	conn, err := net.DialTimeout("unix", forwardproto.Socket, 3*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return err
	}
	if err := forwardproto.Send(conn, 'P', []byte(challenge)); err != nil {
		return err
	}
	kind, response, err := forwardproto.Receive(conn, 64)
	if err != nil || kind != 'P' || len(response) != 64 {
		return errors.New("invalid forwarding readiness response")
	}
	_, err = fmt.Fprintln(os.Stdout, string(response))
	return err
}

func forwardInput(conn net.Conn, stdin io.Reader, credit <-chan struct{}, send sender) {
	buf := make([]byte, forwardproto.Chunk)
	for range credit {
		n, err := stdin.Read(buf)
		// The host can close its input while output and the exit
		// status are still waiting to be read.
		if n != 0 {
			if err := send('I', buf[:n]); err != nil {
				return
			}
			continue
		}
		if err == io.EOF {
			send('I', nil)
			return
		}
		conn.Close()
		return
	}
}

func streamRequest(conn net.Conn, directory, frame string, stdin io.Reader, stdout, stderr io.Writer, send sender, onStart func()) (int, error) {
	if err := send('D', []byte(directory)); err != nil {
		return 1, err
	}
	if err := send('A', []byte(frame)); err != nil {
		return 1, err
	}
	credit := make(chan struct{}, 1)
	defer close(credit)
	started := false
	for {
		kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil {
			return 1, err
		}
		switch {
		case kind == 'S' && len(data) == 0 && !started:
			started = true
			onStart()
			go forwardInput(conn, stdin, credit, send)
		case kind == 'C' && len(data) == 0 && started:
			select {
			case credit <- struct{}{}:
			default:
				return 1, errors.New("unexpected forwarding credit")
			}
		case kind == 'O' && started:
			if _, err := stdout.Write(data); err != nil {
				return 1, err
			}
		case kind == 'E' && started:
			if _, err := stderr.Write(data); err != nil {
				return 1, err
			}
		case kind == 'X' && started && len(data) == 1:
			return int(data[0]), nil
		case kind == 'X' && started && len(data) > 1:
			return 125, &signalExit{string(data)}
		case kind == 'F' && !started:
			_, err = fmt.Fprintf(stderr, "Error: host command forwarding: %s\n", data)
			return 125, err
		case kind == 'L' && !started:
			return 125, &localFallback{string(data)}
		default:
			return 1, errors.New("invalid forwarding response")
		}
	}
}
