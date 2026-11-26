package forwardclient

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
)

// The interrupt test reruns this binary as a client that waits mid-request.
func TestMain(m *testing.M) {
	switch os.Getenv("FORWARDCLIENT_TEST_MODE") {
	case "interrupt":
		interruptedClient()
	case "local":
		os.Exit(Run("forward", os.Args[1:]))
	case "relay":
		os.Exit(runRelayTest(false))
	case "ctrl-c":
		os.Exit(runRelayTest(true))
	case "signal":
		os.Exit(runSignalTest(os.Getenv("FORWARDCLIENT_SIGNAL")))
	}
	os.Exit(m.Run())
}

// interruptedClient sends a request to a server that never answers. Once the
// request has arrived, it reports readiness so the parent can signal it.
func interruptedClient() {
	client, server := net.Pipe()
	go func() {
		for range 2 {
			if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
				os.Exit(3)
			}
		}
		fmt.Println("ready")
		forwardproto.Receive(server, forwardproto.Chunk)
	}()
	status, err := forward(client, "", "unused")
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
	}
	os.Exit(status)
}

func TestStream(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	server.SetDeadline(time.Now().Add(3 * time.Second))
	client.SetDeadline(time.Now().Add(3 * time.Second))
	input := bytes.Repeat([]byte{0, 0xff, '\n'}, forwardproto.Chunk)
	frame, err := argv.Encode("test", []string{"command", "a b"})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() {
		defer server.Close()
		result <- echoRequest(server, frame)
	}()
	var stdout, stderr bytes.Buffer
	status, err := streamRequest(client, "subdir", frame, bytes.NewReader(input), &stdout, &stderr, senderFor(client), func() {})
	if err != nil || status != 42 || !bytes.Equal(stdout.Bytes(), input) || stderr.String() != "error\x00\xff\n" {
		t.Errorf("stream result: %d, %v, %d bytes, %q", status, err, stdout.Len(), stderr.String())
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}

func TestInputWriteErrorKeepsExitStatusReadable(t *testing.T) {
	for _, input := range []string{"", "unread input"} {
		t.Run(fmt.Sprintf("stdin=%q", input), func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			// Fail writes while leaving the server able to send its result.
			if err := client.SetWriteDeadline(time.Now()); err != nil {
				t.Fatal(err)
			}
			if err := client.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
				t.Fatal(err)
			}
			credit := make(chan struct{}, 1)
			credit <- struct{}{}
			close(credit)
			forwardInput(client, strings.NewReader(input), credit, senderFor(client))

			result := make(chan error, 1)
			go func() { result <- forwardproto.Send(server, 'X', []byte{37}) }()
			kind, data, err := forwardproto.Receive(client, forwardproto.Chunk)
			if err != nil || kind != 'X' || !bytes.Equal(data, []byte{37}) {
				t.Fatalf("could not read the exit status: %q %v %v", kind, data, err)
			}
			if err := <-result; err != nil {
				t.Fatal(err)
			}
		})
	}
}

// A service refusal is reported as such, with status 125, so callers can tell
// it apart from the host command's own failures.
func TestStreamRefusal(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	go func() {
		for range 2 {
			if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
				return
			}
		}
		forwardproto.Send(server, 'F', []byte("request does not match the host command policy"))
	}()
	var stdout, stderr bytes.Buffer
	status, err := streamRequest(client, "", "unused", strings.NewReader(""), &stdout, &stderr, senderFor(client), func() {})
	want := "Error: host command forwarding: request does not match the host command policy\n"
	if err != nil || status != 125 || stdout.Len() != 0 || stderr.String() != want {
		t.Errorf("refusal: %d, %v, %q, %q", status, err, stdout.String(), stderr.String())
	}
}

// Local execution replaces the forwarding client, even outside the project
// with arguments too large for the forwarding protocol.
func TestRunOutsideProject(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "command")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$FORWARDCLIENT_MARKER\" \"${#1}\"\ncat\nexit 37\n"), 0700); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "command", strings.Repeat("x", argv.Limit))
	command.Dir = dir
	command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE=local", "FORWARDCLIENT_MARKER=environment", "PATH="+dir+":/usr/bin:/bin")
	command.Stdin = strings.NewReader("input\n")
	output, err := command.CombinedOutput()
	var exit *exec.ExitError
	resolved, errPath := filepath.EvalSymlinks(dir)
	if errPath != nil {
		t.Fatal(errPath)
	}
	want := fmt.Sprintf("%s\nenvironment\n%d\ninput\n", resolved, argv.Limit)
	if !errors.As(err, &exit) || exit.ExitCode() != 37 || string(output) != want {
		t.Fatalf("local execution: %v, %q", err, output)
	}
}

func senderFor(conn net.Conn) sender {
	return func(kind byte, data []byte) error { return forwardproto.Send(conn, kind, data) }
}

// An interrupted client exits with the signal's status and says that the host
// command's outcome is unknown, rather than reporting a result.
func TestForwardInterrupted(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^$")
	command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE=interrupt")
	var stderr bytes.Buffer
	command.Stderr = &stderr
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	ready := make(chan bool, 1)
	go func() {
		line, _ := bufio.NewReader(stdout).ReadString('\n')
		ready <- line == "ready\n"
	}()
	select {
	case ok := <-ready:
		if !ok {
			command.Process.Kill()
			command.Wait()
			t.Fatalf("client did not reach the request: %s", stderr.String())
		}
	case <-time.After(5 * time.Second):
		command.Process.Kill()
		command.Wait()
		t.Fatal("client did not reach the request in time")
	}
	if err := command.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	err = command.Wait()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.Sys().(syscall.WaitStatus).Signal() != syscall.SIGINT ||
		!strings.Contains(stderr.String(), "Command outcome is unknown") {
		t.Errorf("interrupted client: %v, %q", err, stderr.String())
	}
}

func echoRequest(conn net.Conn, frame string) error {
	for _, want := range []struct {
		kind byte
		data string
	}{{'D', "subdir"}, {'A', frame}} {
		kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if kind != want.kind || string(data) != want.data || err != nil {
			return fmt.Errorf("metadata %c %q: %v", kind, data, err)
		}
	}
	if err := forwardproto.Send(conn, 'S', nil); err != nil {
		return err
	}
	for {
		if err := forwardproto.Send(conn, 'C', nil); err != nil {
			return err
		}
		kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if kind != 'I' || err != nil {
			return fmt.Errorf("input message %c: %v", kind, err)
		}
		if len(data) == 0 {
			break
		}
		if err := forwardproto.Send(conn, 'O', data); err != nil {
			return err
		}
	}
	if err := forwardproto.Send(conn, 'E', []byte("error\x00\xff\n")); err != nil {
		return err
	}
	return forwardproto.Send(conn, 'X', []byte{42})
}

// Exercise the actual process termination rather than a 128+signal exit code.
func runSignalTest(name string) int {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		for range 2 {
			if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
				return
			}
		}
		if err := forwardproto.Send(server, 'S', nil); err != nil {
			return
		}
		if name == "numeric" {
			forwardproto.Send(server, 'X', []byte{130})
		} else {
			forwardproto.Send(server, 'X', []byte(name))
		}
	}()
	status, err := forward(client, "", "unused")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	return status
}

func TestSignalExit(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the distributed client runs on Linux")
	}
	for _, name := range []string{"SIGABRT", "SIGUSR1", "SIGQUIT", "SIGINT", "SIGEMT", "SIGRTMIN+2"} {
		t.Run(name, func(t *testing.T) {
			command := exec.Command(os.Args[0], "-test.run=^$")
			command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE=signal", "FORWARDCLIENT_SIGNAL="+name)
			output, err := command.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) {
				t.Fatalf("termination: %v, %s", err, output)
			}
			status := exit.Sys().(syscall.WaitStatus)
			if sig := forwardproto.SignalNumber(name); sig == 0 {
				if exit.ExitCode() != 125 || !strings.Contains(string(output), "no local equivalent") {
					t.Fatalf("unknown signal: %v, %s", err, output)
				}
			} else if !status.Signaled() || status.Signal() != sig || len(output) != 0 {
				t.Fatalf("termination: %v, %s", err, output)
			}
		})
	}
}

// A fallback reply must arrive before any reading of stdin, and must never
// be confused with an execution failure after the command started.
func TestFallbackResponse(t *testing.T) {
	for _, started := range []bool{false, true} {
		client, server := net.Pipe()
		client.SetDeadline(time.Now().Add(time.Second))
		go func() {
			defer server.Close()
			for range 2 {
				if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
					return
				}
			}
			if started {
				forwardproto.Send(server, 'S', nil)
			}
			forwardproto.Send(server, 'L', []byte("unmatched"))
		}()
		input := strings.NewReader("untouched")
		var output bytes.Buffer
		_, err := streamRequest(client, "", "unused", input, &output, &output, senderFor(client), func() {})
		var fallback *localFallback
		if errors.As(err, &fallback) == started || input.Len() != len("untouched") {
			t.Errorf("started=%v: %v, %d bytes remaining", started, err, input.Len())
		}
		client.Close()
	}
}

func runRelayTest(interrupt bool) int {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		for range 2 {
			if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
				return
			}
		}
		if err := forwardproto.Send(server, 'S', nil); err != nil {
			return
		}
		if !interrupt {
			if err := forwardproto.Send(server, 'C', nil); err != nil {
				return
			}
		}
		if err := forwardproto.Send(server, 'O', []byte("ready\n")); err != nil {
			return
		}
		if interrupt {
			// No stdin credit: the mock host terminates when it receives Ctrl-C.
			kind, data, err := forwardproto.Receive(server, forwardproto.Chunk)
			if err == nil && kind == 'G' && string(data) == "SIGINT" {
				forwardproto.Send(server, 'X', []byte("SIGINT"))
			}
			return
		}
		for range 3 {
			kind, data, err := forwardproto.Receive(server, forwardproto.Chunk)
			if err != nil || kind != 'G' {
				return
			}
			if err := forwardproto.Send(server, 'O', append(data, '\n')); err != nil {
				return
			}
		}
		forwardproto.Send(server, 'X', []byte{37})
	}()
	status, err := forward(client, "", "unused")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	return status
}

func TestRelaySignals(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^$")
	command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE=relay")
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer command.Wait()
	defer command.Process.Kill()
	reader := bufio.NewReader(stdout)
	if line, err := reader.ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("ready: %q %v", line, err)
	}
	for _, entry := range []struct {
		signal syscall.Signal
		name   string
	}{{syscall.SIGINT, "SIGINT"}, {syscall.SIGTERM, "SIGTERM"}, {syscall.SIGINT, "SIGINT"}} {
		if err := command.Process.Signal(entry.signal); err != nil {
			t.Fatal(err)
		}
		if line, err := reader.ReadString('\n'); err != nil || line != entry.name+"\n" {
			t.Fatalf("relayed signal: %q %v", line, err)
		}
	}
	var exit *exec.ExitError
	if err := command.Wait(); !errors.As(err, &exit) || exit.ExitCode() != 37 || stderr.Len() != 0 {
		t.Fatalf("relay exit: %v %s", err, stderr.String())
	}
}

func TestNumericExitAndBashInterrupt(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^$")
	command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE=signal", "FORWARDCLIENT_SIGNAL=numeric")
	var exit *exec.ExitError
	if err := command.Run(); !errors.As(err, &exit) || exit.ExitCode() != 130 {
		t.Fatalf("numeric 130: %v", err)
	}
	for _, mode := range []string{"ctrl-c", "interrupt"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			// A terminal sends Ctrl-C to the entire foreground process group,
			// including Bash while it waits for the forwarded command.
			command := exec.CommandContext(ctx, "bash", "-c", `while :; do "$1" -test.run='^$'; echo loop-continued; exit 99; done`, "bash", os.Args[0])
			command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_MODE="+mode)
			stdout, err := command.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			var stderr bytes.Buffer
			command.Stderr = &stderr
			if err := command.Start(); err != nil {
				t.Fatal(err)
			}
			defer command.Wait()
			defer command.Process.Kill()
			reader := bufio.NewReader(stdout)
			if line, err := reader.ReadString('\n'); err != nil || line != "ready\n" {
				t.Fatalf("ready: %q %v", line, err)
			}
			if err := syscall.Kill(-command.Process.Pid, syscall.SIGINT); err != nil {
				t.Fatal(err)
			}
			tail, err := io.ReadAll(reader)
			if err != nil {
				t.Fatal(err)
			}
			err = command.Wait()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || ctx.Err() != nil || strings.Contains(string(tail), "loop-continued") || !(exit.ExitCode() == 130 || exit.Sys().(syscall.WaitStatus).Signal() == syscall.SIGINT) {
				t.Fatalf("bash loop not interrupted: %v %q", err, tail)
			}
			if mode == "interrupt" && !strings.Contains(stderr.String(), "Command outcome is unknown") {
				t.Fatalf("missing diagnostic: %s", stderr.String())
			}
		})
	}
}

func TestConnectionLostAfterStart(t *testing.T) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		for range 2 {
			if _, _, err := forwardproto.Receive(server, forwardproto.Chunk); err != nil {
				return
			}
		}
		forwardproto.Send(server, 'S', nil)
	}()
	status, err := forward(client, "", "unused")
	if status == 0 || err == nil || !strings.Contains(err.Error(), "Command outcome is unknown") {
		t.Fatalf("lost connection: %d %v", status, err)
	}
}
