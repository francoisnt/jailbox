package forwardclient

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
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
	frame, err := argv.Encode("forwarded command", args)
	if err != nil {
		return 1, err
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
			return 1, errors.New("forwarded commands must run inside the sandbox project")
		}
	}
	if len(relative) > forwardproto.DirectoryLimit {
		return 1, errors.New("forwarded working directory is too long")
	}
	conn, err := net.Dial("unix", forwardproto.Socket)
	if err != nil {
		return 1, errors.New("service unavailable. Run 'jailbox stop' then 'jailbox up'")
	}
	return forward(conn, relative, frame)
}

// forward sends one request over conn and streams it. A signal ends the
// program at once, because the host command's outcome is then unknown.
func forward(conn net.Conn, relative, frame string) (int, error) {
	defer conn.Close()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(signals)
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case sig := <-signals:
			conn.Close()
			fmt.Fprintln(os.Stderr, "Error: host command forwarding interrupted. Command outcome is unknown.")
			os.Exit(128 + int(sig.(syscall.Signal)))
		case <-finished:
		}
	}()
	status, err := stream(conn, relative, frame, os.Stdin, os.Stdout, os.Stderr)
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

func stream(conn net.Conn, directory, frame string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	if err := forwardproto.Send(conn, 'D', []byte(directory)); err != nil {
		return 1, err
	}
	if err := forwardproto.Send(conn, 'A', []byte(frame)); err != nil {
		return 1, err
	}
	credit := make(chan struct{}, 1)
	defer close(credit)
	go func() {
		buf := make([]byte, forwardproto.Chunk)
		for range credit {
			n, err := stdin.Read(buf)
			if n != 0 {
				if writeErr := forwardproto.Send(conn, 'I', buf[:n]); writeErr != nil {
					conn.Close()
					return
				}
				continue
			}
			if err == io.EOF {
				if err := forwardproto.Send(conn, 'I', nil); err == nil {
					return
				}
			}
			conn.Close()
			return
		}
	}()
	for {
		kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil {
			return 1, err
		}
		switch {
		case kind == 'C' && len(data) == 0:
			select {
			case credit <- struct{}{}:
			default:
				return 1, errors.New("unexpected forwarding credit")
			}
		case kind == 'O':
			if _, err := stdout.Write(data); err != nil {
				return 1, err
			}
		case kind == 'E':
			if _, err := stderr.Write(data); err != nil {
				return 1, err
			}
		case kind == 'X' && len(data) == 1:
			return int(data[0]), nil
		case kind == 'F':
			_, err = fmt.Fprintf(stderr, "Error: host command forwarding: %s\n", data)
			return 125, err
		default:
			return 1, errors.New("invalid forwarding response")
		}
	}
}
