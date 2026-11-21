package forwarding

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
	"golang.org/x/sys/unix"
)

func request(generation string) error {
	// startRequest passes the connection as descriptor 3 and the service
	// lifetime pipe as 4.
	unix.CloseOnExec(3)
	unix.CloseOnExec(4)
	socket := os.NewFile(3, "forwarding request")
	conn, err := net.FileConn(socket)
	socket.Close()
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	lifetime := os.NewFile(4, "forwarding service lifetime")
	go func() {
		var byteRead [1]byte
		lifetime.Read(byteRead[:])
		lifetime.Close()
		cancel()
	}()
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	conn.SetDeadline(time.Now().Add(4 * time.Second))
	kind, directory, err := forwardproto.Receive(conn, forwardproto.DirectoryLimit)
	if err != nil {
		return refusal(conn, err)
	}
	saved, err := loadManifest()
	if err != nil {
		return refusal(conn, err)
	}
	if kind == 'P' && generationID.Match(directory) {
		return forwardproto.Send(conn, 'P', saved.probeResponse(generation, directory))
	}
	if kind != 'D' {
		return refusal(conn, errors.New("expected forwarding working directory"))
	}
	kind, frame, err := forwardproto.Receive(conn, argv.Limit)
	if err != nil {
		return refusal(conn, err)
	}
	if kind != 'A' {
		return refusal(conn, errors.New("expected forwarding arguments"))
	}
	args, err := argv.Decode(string(frame))
	if err != nil {
		return refusal(conn, err)
	}
	contents, err := os.ReadFile(policyFile)
	if err != nil {
		return refusal(conn, err)
	}
	if hash(contents) != saved.Hash {
		return refusal(conn, errors.New("forwarding policy snapshot has changed"))
	}
	// The request process has no child at this point. A wall clock limit
	// covers policy compilation, matching and directory validation.
	// On expiry, refuse so the client knows the command never ran.
	timer := time.AfterFunc(time.Second, func() {
		conn.SetWriteDeadline(time.Now().Add(50 * time.Millisecond))
		refusal(conn, errors.New("forwarding policy matching timed out"))
		os.Exit(1)
	})
	rules, err := compilePolicy(string(contents), nil)
	if err == nil {
		err = rules.authorize(args)
	}
	if err == nil {
		err = saved.enterProject(string(directory))
	}
	if !timer.Stop() {
		// The expired timer sends the refusal and ends this process.
		select {}
	}
	if err != nil {
		return refusal(conn, err)
	}
	path := string(saved.Executables[args[0]])
	if path == "" {
		return refusal(conn, errors.New("host executable unavailable in policy preparation"))
	}
	if ctx.Err() != nil {
		return nil
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return err
	}

	// This process is the live group leader. The child inherits its pinned
	// current directory and group. Only the executable pathname is mapped.
	unix.Umask(saved.Umask)
	cmd := &exec.Cmd{Path: path, Args: args}
	return execute(ctx, conn, cmd)
}

func refusal(conn net.Conn, err error) error {
	return forwardproto.Send(conn, 'F', []byte(err.Error()))
}

func cancelGroup() {
	// The worker is still alive, so this group ID cannot have been reused.
	unix.Kill(-os.Getpid(), unix.SIGTERM)
	time.Sleep(terminationGrace)
	unix.Kill(-os.Getpid(), unix.SIGKILL)
}

func execute(ctx context.Context, conn net.Conn, cmd *exec.Cmd) error {
	inputRead, input, err := os.Pipe()
	if err != nil {
		return refusal(conn, err)
	}
	defer inputRead.Close()
	defer input.Close()
	stdout, stdoutWrite, err := os.Pipe()
	if err != nil {
		return refusal(conn, err)
	}
	defer stdout.Close()
	defer stdoutWrite.Close()
	stderr, stderrWrite, err := os.Pipe()
	if err != nil {
		return refusal(conn, err)
	}
	defer stderr.Close()
	defer stderrWrite.Close()

	cmd.Stdin, cmd.Stdout, cmd.Stderr = inputRead, stdoutWrite, stderrWrite
	if err := cmd.Start(); err != nil {
		var pathError *os.PathError
		if errors.As(err, &pathError) {
			err = pathError.Err
		}
		return refusal(conn, fmt.Errorf("host executable could not start: %w", err))
	}
	inputRead.Close()
	stdoutWrite.Close()
	stderrWrite.Close()

	var lock sync.Mutex
	send := func(kind byte, data []byte) error {
		lock.Lock()
		defer lock.Unlock()
		return forwardproto.Send(conn, kind, data)
	}
	var credited atomic.Bool
	inputChunks := make(chan []byte, 1)
	go pushInput(conn, input, send, inputChunks, &credited)
	disconnected := make(chan struct{})
	go func() {
		readInput(conn, inputChunks, &credited)
		close(disconnected)
	}()

	var outputs sync.WaitGroup
	for _, output := range []struct {
		kind byte
		pipe *os.File
	}{{'O', stdout}, {'E', stderr}} {
		outputs.Go(func() {
			chunk := make([]byte, forwardproto.Chunk)
			for {
				n, err := output.pipe.Read(chunk)
				if n > 0 {
					if err := send(output.kind, chunk[:n]); err != nil {
						conn.Close()
						return
					}
				}
				if err != nil {
					if err != io.EOF {
						conn.Close()
					}
					return
				}
			}
		})
	}

	result := make(chan byte, 1)
	go func() {
		cmd.Wait()
		outputs.Wait()
		status := cmd.ProcessState.Sys().(syscall.WaitStatus)
		if status.Signaled() {
			result <- byte(128 + status.Signal())
		} else {
			result <- byte(status.ExitStatus())
		}
	}()

	// readInput closes the connection on disconnect. Track that closure
	// independently of output so a silent program also gets canceled.
	select {
	case <-ctx.Done():
	case <-disconnected:
	case status := <-result:
		if ctx.Err() == nil && send('X', []byte{status}) == nil {
			return nil
		}
	}
	cancelGroup()
	return nil
}

func pushInput(conn net.Conn, input *os.File, send func(byte, []byte) error, chunks <-chan []byte, credited *atomic.Bool) {
	defer input.Close()
	for {
		credited.Store(true)
		if err := send('C', nil); err != nil {
			conn.Close()
			return
		}
		data := <-chunks
		if len(data) == 0 {
			return
		}
		if _, err := input.Write(data); err != nil {
			// A command can close stdin and continue writing output.
			if !errors.Is(err, syscall.EPIPE) {
				conn.Close()
			}
			return
		}
	}
}

func readInput(conn net.Conn, chunks chan<- []byte, credited *atomic.Bool) {
	inputClosed := false
	for {
		kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil || kind != 'I' || inputClosed || !credited.Swap(false) {
			conn.Close()
			return
		}
		chunks <- data
		inputClosed = len(data) == 0
	}
}
