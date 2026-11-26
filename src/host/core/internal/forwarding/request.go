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
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
	"golang.org/x/sys/unix"
)

func request(generation string, matchingLimit time.Duration) error {
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
	// The worker stays in the command's group but must not terminate in
	// response to signals forwarded to that group. The service lifetime pipe
	// and request connection independently own cancellation.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	ctx, cancel := context.WithCancel(context.Background())
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
	timeout := errors.New("forwarding policy matching timed out")
	deadline := time.Now().Add(matchingLimit)
	timer := time.AfterFunc(time.Until(deadline), func() {
		conn.SetWriteDeadline(time.Now().Add(50 * time.Millisecond))
		refusal(conn, timeout)
		os.Exit(1)
	})
	finishChecks := func() error {
		if !timer.Stop() {
			// The expired timer sends the refusal and ends this process.
			select {}
		}
		// Stop can win against a delayed timer callback after the deadline.
		if !time.Now().Before(deadline) {
			return timeout
		}
		return nil
	}
	stateDir, stateErr := unix.Getwd()
	rules, err := compilePolicy(string(contents), nil)
	if err != nil {
		if timeoutErr := finishChecks(); timeoutErr != nil {
			return refusal(conn, timeoutErr)
		}
		return refusal(conn, err)
	}
	matchErr := rules.authorize(args)
	resolved, resolveErr := rules.resolve(args)
	directoryErr := saved.enterProject(string(directory))
	path := string(saved.Executables[args[0]])
	var executableErr error
	if rules.hasRules(args[0]) {
		info, statErr := os.Stat(path)
		if path == "" || statErr != nil || !info.Mode().IsRegular() || unix.Access(path, unix.X_OK) != nil {
			executableErr = errors.New("host executable could not start: unavailable")
		}
	}
	if err := finishChecks(); err != nil {
		return refusal(conn, err)
	}
	if ctx.Err() != nil {
		return nil
	}
	if err := conn.SetDeadline(time.Time{}); err != nil {
		return err
	}
	matched := matchErr == nil
	if stateErr == nil && (matched || errors.Is(matchErr, errUnmatched)) && (resolved.log == "all" || (resolved.log == "unmatched" && !matched)) {
		logMatch(filepath.Dir(stateDir), string(directory), args, matched)
	}
	// Eligibility is distinct from errors: an unmatched or hidden request
	// must not hide a failed pre-execution check.
	for _, checkErr := range []error{resolveErr, executableErr, directoryErr, matchErr} {
		if checkErr != nil && !errors.Is(checkErr, errHiddenDirectory) && !errors.Is(checkErr, errUnmatched) {
			return refusal(conn, checkErr)
		}
	}
	if directoryErr != nil || matchErr != nil {
		reason := directoryErr
		if reason == nil {
			reason = matchErr
		}
		if resolved.fallback {
			return forwardproto.Send(conn, 'L', []byte(reason.Error()))
		}
		return refusal(conn, reason)
	}
	if ctx.Err() != nil {
		return nil
	}

	// This process is the live group leader. The child inherits its pinned
	// current directory and group. Only the executable pathname is mapped.
	unix.Umask(saved.Umask)
	cmd := &exec.Cmd{Path: path, Args: resolved.args}
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
	if err := forwardproto.Send(conn, 'S', nil); err != nil {
		cancelGroup()
		return err
	}

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

	result := make(chan []byte, 1)
	go func() {
		cmd.Wait()
		outputs.Wait()
		status := cmd.ProcessState.Sys().(syscall.WaitStatus)
		if status.Signaled() {
			name := forwardproto.SignalName(status.Signal())
			if name == "" {
				name = "UNKNOWN"
			}
			result <- []byte(name)
		} else {
			result <- []byte{byte(status.ExitStatus())}
		}
	}()

	// readInput closes the connection on disconnect. Track that closure
	// independently of output so a silent program also gets canceled.
	select {
	case <-ctx.Done():
	case <-disconnected:
	case status := <-result:
		if ctx.Err() == nil && send('X', status) == nil {
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
		if err == nil && kind == 'G' {
			sig := forwardproto.SignalNumber(string(data))
			if sig == unix.SIGINT || sig == unix.SIGTERM || sig == unix.SIGHUP {
				if unix.Kill(-os.Getpid(), sig) == nil {
					continue
				}
			}
		}
		if err != nil || kind != 'I' || inputClosed || !credited.Swap(false) {
			conn.Close()
			return
		}
		chunks <- data
		inputClosed = len(data) == 0
	}
}
