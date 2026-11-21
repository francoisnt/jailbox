package forwardclient

import (
	"bytes"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/forwardproto"
)

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
