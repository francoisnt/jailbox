package forwardclient

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
)

// The interrupt test reruns this binary as a client that waits mid-request.
func TestMain(m *testing.M) {
	if os.Getenv("FORWARDCLIENT_TEST_INTERRUPT") == "1" {
		interruptedClient()
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
	forward(client, "", "unused")
	os.Exit(4)
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
	status, err := stream(client, "subdir", frame, bytes.NewReader(input), &stdout, &stderr)
	if err != nil || status != 42 || !bytes.Equal(stdout.Bytes(), input) || stderr.String() != "error\x00\xff\n" {
		t.Errorf("stream result: %d, %v, %d bytes, %q", status, err, stdout.Len(), stderr.String())
	}
	if err := <-result; err != nil {
		t.Fatal(err)
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
	status, err := stream(client, "", "unused", strings.NewReader(""), &stdout, &stderr)
	want := "Error: host command forwarding: request does not match the host command policy\n"
	if err != nil || status != 125 || stdout.Len() != 0 || stderr.String() != want {
		t.Errorf("refusal: %d, %v, %q, %q", status, err, stdout.String(), stderr.String())
	}
}

// The client refuses before connecting when it runs outside the project.
func TestRunOutsideProject(t *testing.T) {
	t.Chdir(t.TempDir())
	status, err := run("forward", []string{"command"})
	if status != 1 || err == nil || !strings.Contains(err.Error(), "inside the sandbox project") {
		t.Errorf("outside project: %d, %v", status, err)
	}
}

// An interrupted client exits with the signal's status and says that the host
// command's outcome is unknown, rather than reporting a result.
func TestForwardInterrupted(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^$")
	command.Env = append(os.Environ(), "FORWARDCLIENT_TEST_INTERRUPT=1")
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
	if !errors.As(err, &exit) || exit.ExitCode() != 128+int(syscall.SIGINT) ||
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
