package forwarding

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/francoisnt/jailbox/internal/argv"
	"github.com/francoisnt/jailbox/internal/buildversion"
	"github.com/francoisnt/jailbox/internal/forwardproto"
	"golang.org/x/sys/unix"
)

func TestMain(m *testing.M) {
	switch {
	case len(os.Args) > 2 && os.Args[1] == buildversion.Version:
		if err := Run(os.Args[2], os.Args[3:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	case len(os.Args) == 3 && os.Args[1] == "test-pinned-directory":
		if err := testPinnedDirectory(os.Args[2]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	default:
		os.Exit(m.Run())
	}
}

type socketFixture struct {
	project, state, server, executable, pids string
	generation                               string
	// program, when set, is a copy of the test binary that runs every helper.
	program string
}

func (fixture socketFixture) tool(input []byte, args ...string) ([]byte, error) {
	self := fixture.program
	if self == "" {
		var err error
		if self, err = os.Executable(); err != nil {
			return nil, err
		}
	}
	cmd := exec.Command(self, append([]string{buildversion.Version}, args...)...)
	cmd.Stdin = bytes.NewReader(input)
	return cmd.CombinedOutput()
}

func (fixture socketFixture) mustTool(t *testing.T, input []byte, args ...string) []byte {
	t.Helper()
	output, err := fixture.tool(input, args...)
	if err != nil {
		t.Fatalf("%s: %v: %s", args[0], err, output)
	}
	return output
}

func writeFixture(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func newSocketFixture(t *testing.T) socketFixture {
	t.Helper()
	return newSocketFixtureWith(t, false)
}

func newSocketFixtureWith(t *testing.T, copyProgram bool) socketFixture {
	t.Helper()
	// Keep the test client's absolute address short even on macOS. The
	// service itself uses relative socket addresses for every installation.
	dir, err := os.MkdirTemp("/tmp", "jailbox-go-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	source, err := filepath.Abs("../../../..")
	if err != nil {
		t.Fatal(err)
	}
	fixture := socketFixture{
		project: filepath.Join(root, "project"), state: filepath.Join(root, "state"),
		server: filepath.Join(root, "server"), executable: filepath.Join(root, "bin", "forwarded-command"),
		pids: filepath.Join(root, "tunnel-pids"), generation: strings.Repeat("a", 64),
	}
	for _, path := range []string{fixture.project + "/data/hidden", fixture.server, filepath.Dir(fixture.executable)} {
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	hostCommand, err := os.ReadFile(filepath.Join(source, "../tests/fixtures/forwarding/host-command.py"))
	if err != nil {
		t.Fatal(err)
	}
	writeFixture(t, fixture.executable, string(hostCommand), 0755)
	if copyProgram {
		self, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		program, err := os.ReadFile(self)
		if err != nil {
			t.Fatal(err)
		}
		fixture.program = filepath.Join(root, "program", "jailbox-core")
		if err := os.Mkdir(filepath.Dir(fixture.program), 0755); err != nil {
			t.Fatal(err)
		}
		writeFixture(t, fixture.program, string(program), 0755)
	}
	writeFixture(t, filepath.Join(root, "bin", "ssh"), "#!/bin/sh\nprintf '%s\\n' \"$PPID\" \"$$\" > '"+fixture.pids+
		"'\nexec /bin/cat >/dev/null\n", 0755)
	t.Setenv("PATH", filepath.Join(root, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FORWARDING_TEST_HOST", "launch-time-host")
	policy := "forwarded-command stream\nforwarded-command args '' {{.*}} {{.*}}\n" +
		"forwarded-command directory {{.*}}\nforwarded-command hold\n" +
		"forwarded-command effect one\nforwarded-command effect {{.*}}\nforwarded-command terminal\n" +
		"forwarded-command first-line\n"
	writeFixture(t, fixture.project+"/policy", policy, 0644)
	frame := fixture.mustTool(t, nil, "capture", fixture.project, "policy")
	manifest := fixture.mustTool(t, frame, "describe", fixture.project, source)
	fixture.mustTool(t, append(frame, manifest...), "publish", fixture.project, fixture.state, fixture.server,
		strings.TrimSpace(string(fixture.mustTool(t, frame, "hash"))), "data/hidden")
	t.Cleanup(func() {
		if _, err := os.Stat(fixture.state); err == nil {
			fixture.mustTool(t, nil, "retire", fixture.state)
		}
	})
	mounts, err := json.Marshal([]map[string]any{{"RW": true, "Type": "volume", "Source": root + "/home"}})
	if err != nil {
		t.Fatal(err)
	}
	fixture.mustTool(t, mounts, "start", fixture.state, fixture.generation, "/unused", "fixture")
	deadline := time.Now().Add(5 * time.Second)
	for {
		info, statErr := os.Stat(fixture.pids)
		health, checkErr := fixture.tool(nil, "check", fixture.state, fixture.generation)
		if statErr == nil && info.Size() > 0 && checkErr == nil {
			break
		}
		if time.Now().After(deadline) {
			log, _ := os.ReadFile(filepath.Join(fixture.state, logFile))
			t.Fatalf("forwarding fixture did not become ready: %s%s", log, health)
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fixture
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for forwarding fixture")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (fixture socketFixture) dial() (net.Conn, error) {
	conn, err := net.DialTimeout("unix", filepath.Join(fixture.state, requestSocket), time.Second)
	if err != nil {
		return nil, err
	}
	return conn, conn.SetDeadline(time.Now().Add(5 * time.Second))
}

func (fixture socketFixture) request(directory string, args ...string) (net.Conn, error) {
	frame, err := argv.Encode("test forwarding request", append([]string{"forwarded-command"}, args...))
	if err != nil {
		return nil, err
	}
	conn, err := fixture.dial()
	if err != nil {
		return nil, err
	}
	if err = forwardproto.Send(conn, 'D', []byte(directory)); err == nil {
		err = forwardproto.Send(conn, 'A', []byte(frame))
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

type execution struct {
	kind   byte
	result string
	stdout string
	stderr string
}

func (fixture socketFixture) collect(directory string, input []byte, args ...string) (execution, error) {
	conn, err := fixture.request(directory, args...)
	if err != nil {
		return execution{}, err
	}
	defer conn.Close()
	var stdout, stderr strings.Builder
	for {
		kind, value, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil {
			return execution{}, err
		}
		switch kind {
		case 'C':
			n := min(len(input), forwardproto.Chunk)
			if err := forwardproto.Send(conn, 'I', input[:n]); err != nil {
				return execution{}, err
			}
			input = input[n:]
		case 'O':
			stdout.Write(value)
		case 'E':
			stderr.Write(value)
		default:
			return execution{kind, string(value), stdout.String(), stderr.String()}, nil
		}
	}
}

func TestSocketRequests(t *testing.T) {
	fixture := newSocketFixture(t)
	require := func(directory string, input []byte, args ...string) execution {
		t.Helper()
		got, err := fixture.collect(directory, input, args...)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	writeFixture(t, fixture.project+"/policy", "forwarded-command changed\n", 0644)
	for i, data := range [][]byte{bytes.Repeat([]byte("\x00\xff\n"), 100000), []byte("some input\x00\xff\n")} {
		t.Run(fmt.Sprintf("binary stream %d", i), func(t *testing.T) {
			t.Parallel()
			if got, err := fixture.collect("", data, "stream"); err != nil || got != (execution{'X', "*", string(data), "error\x00\xff\n"}) {
				t.Errorf("stream did not preserve result and payload (%c, %q, %d stdout bytes, %q stderr): %v",
					got.kind, got.result, len(got.stdout), got.stderr, err)
			}
		})
	}
	// The command closes stdin while far more input than a pipe holds is still
	// arriving. Its later output and exit status must still come through.
	input := append([]byte("first line\n"), bytes.Repeat([]byte("more input\n"), 200000)...)
	if got := require("", input, "first-line"); got != (execution{'X', "\x00", "first line\nstill running\n", ""}) {
		t.Fatalf("command that stops reading stdin early: %#v", got)
	}
	if got := require("", nil, "args", "", "\xff\n'$x*", "hello world\n"); got != (execution{'X', "\x00", "\x00\xff\n'$x*\x00hello world\n\x00", ""}) {
		t.Fatalf("argument preservation: %#v", got)
	}
	if got := require("", nil, "terminal"); got.stdout != "False False False\n" {
		t.Fatalf("host command inherited a terminal: %#v", got)
	}
	for path, mode := range map[string]os.FileMode{fixture.server + "/host-commands/forwarded-command": 0755, fixture.state + "/policy": 0600} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("%s: want mode %o, got %v, %v", path, mode, info, err)
		}
	}
	if err := os.Symlink(filepath.Dir(fixture.project), fixture.project+"/escape"); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{"escape", "../project", "/", "data/../data"} {
		if got := require(directory, nil, "directory", "marker"); got.kind != 'F' {
			t.Fatalf("directory %q accepted: %#v", directory, got)
		}
	}
	for _, args := range [][]string{{"effect", "one"}, {"effect", "one", "extra"}} {
		if got := require("", nil, args...); got.kind != 'F' {
			t.Fatalf("invalid request accepted: %#v", got)
		}
	}
	if _, err := os.Stat(fixture.project + "/forwarded-effect"); !os.IsNotExist(err) {
		t.Fatalf("invalid request had a host effect: %v", err)
	}
	if err := os.Rename(fixture.project+"/data", fixture.project+"/moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(fixture.project+"/data/hidden", 0755); err != nil {
		t.Fatal(err)
	}
	if got := require("moved/hidden/missing", nil, "directory", "marker"); got.kind != 'F' ||
		!strings.Contains(got.result, "working directory is hidden by HIDDEN_PATHS") {
		t.Fatalf("moved hidden path accepted: %#v", got)
	}
	for _, directory := range []string{"data/hidden", "moved"} {
		path := filepath.Join(fixture.project, directory)
		writeFixture(t, filepath.Dir(path)+"/marker", "parent path argument\n", 0644)
		t.Run(directory, func(t *testing.T) {
			t.Parallel()
			want := execution{'X', "\x00", path + "\nlaunch-time-host\nparent path argument\n", ""}
			got, err := fixture.collect(directory, nil, "directory", "../marker")
			if err != nil || got != want {
				t.Errorf("mapped directory %q: %#v, %v", directory, got, err)
			}
		})
	}

	conn, err := fixture.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := forwardproto.Send(conn, 'D', nil); err != nil {
		t.Fatal(err)
	}
	if err := forwardproto.Send(conn, 'A', []byte(strings.Repeat("!", argv.Limit))); err != nil {
		t.Fatal(err)
	}
	if kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk); kind != 'F' || err != nil {
		t.Fatalf("malformed frame response: %c, %v", kind, err)
	}
}

func TestUnavailableHostExecutable(t *testing.T) {
	fixture := newSocketFixture(t)
	if err := os.Remove(fixture.executable); err != nil {
		t.Fatal(err)
	}
	result, err := fixture.collect("", nil, "terminal")
	if err != nil || result.kind != 'F' || !strings.Contains(result.result, "host executable could not start") {
		t.Fatalf("unavailable executable: %#v, %v", result, err)
	}
}

func TestRequestStartFailureKeepsService(t *testing.T) {
	fixture := newSocketFixtureWith(t, true)
	program, err := os.ReadFile(fixture.program)
	if err != nil {
		t.Fatal(err)
	}
	// Cleanups run last-in first-out, so retirement finds the program again.
	t.Cleanup(func() { writeFixture(t, fixture.program, string(program), 0755) })
	if err := os.Remove(fixture.program); err != nil {
		t.Fatal(err)
	}
	result, err := fixture.collect("", nil, "stream")
	if err != nil || result.kind != 'F' || result.result != "could not start the forwarded request" {
		t.Fatalf("request that could not start: %#v, %v", result, err)
	}
	writeFixture(t, fixture.program, string(program), 0755)
	result, err = fixture.collect("", []byte("still serving"), "stream")
	if err != nil || result.kind != 'X' || result.stdout != "still serving" {
		t.Fatalf("service stopped after a request failed to start: %#v, %v", result, err)
	}
}

// processGone reports whether a process has exited. An exited process can
// linger as a zombie when nothing reaps it, which also counts as gone.
func processGone(pid int) bool {
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return unix.Kill(pid, 0) == unix.ESRCH
	}
	end := bytes.LastIndexByte(stat, ')')
	return end < 0 || end+2 >= len(stat) || stat[end+2] == 'Z'
}

// startStubbornWorker starts a group leader and a descendant that both ignore
// SIGTERM, like a worker that cannot respond in time. It returns the leader
// and the descendant's process ID.
func startStubbornWorker(t *testing.T) (*child, int) {
	t.Helper()
	pidFile := filepath.Join(t.TempDir(), "descendant")
	script := `trap "" TERM; sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 30' sh "$0" & wait`
	command := exec.Command("/bin/sh", "-c", script, pidFile)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	leader, err := startChild(command)
	if err != nil {
		t.Fatal(err)
	}
	return leader, descendantPID(t, pidFile)
}

// descendantPID waits for a test script to record its descendant's process
// ID and kills that descendant when the test ends.
func descendantPID(t *testing.T, pidFile string) int {
	t.Helper()
	var pid int
	waitFor(t, func() bool {
		data, err := os.ReadFile(pidFile)
		if err != nil {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(data)))
		return err == nil
	})
	t.Cleanup(func() { unix.Kill(pid, unix.SIGKILL) })
	return pid
}

// Only the forced group kill stops the descendant, and shutdown succeeds
// once the killed leader is confirmed gone.
func TestForcedShutdownKillsProcessGroup(t *testing.T) {
	leader, pid := startStubbornWorker(t)
	if err := stopChildren(map[*child]bool{leader: true}); err != nil {
		t.Fatalf("forced shutdown of a killable worker: %v", err)
	}
	waitFor(t, func() bool { return processGone(pid) })
}

// A child that already exited does not turn a successful forced stop into
// a failure.
func TestForcedShutdownWithExitedChild(t *testing.T) {
	command := exec.Command("/bin/sh", "-c", "exit 0")
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	exited, err := startChild(command)
	if err != nil {
		t.Fatal(err)
	}
	<-exited.done
	leader, pid := startStubbornWorker(t)
	if err := stopChildren(map[*child]bool{exited: true, leader: true}); err != nil {
		t.Fatalf("forced shutdown with an exited child: %v", err)
	}
	waitFor(t, func() bool { return processGone(pid) })
}

// When exit cannot be watched, the child's whole group is killed before it
// is reaped, so nothing it started outlives the lost watch.
func TestUnwatchableChildKillsProcessGroup(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "descendant")
	script := `sh -c 'echo $$ > "$1"; exec sleep 30' sh "$0" & wait`
	command := exec.Command("/bin/sh", "-c", script, pidFile)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	pid := descendantPID(t, pidFile)
	unwatched := &child{process: command.Process, done: make(chan struct{})}
	go unwatched.finish(command, errors.New("exit watch failed"))
	<-unwatched.done
	waitFor(t, func() bool { return processGone(pid) })
}

func TestSocketHealthAndCancellation(t *testing.T) {
	for _, cause := range []string{"disconnect", "retire", "service death", "ssh death"} {
		t.Run(cause, func(t *testing.T) {
			fixture := newSocketFixture(t)
			if _, err := fixture.tool(nil, "check", fixture.state, strings.Repeat("b", 64)); err == nil {
				t.Fatal("different generation accepted")
			}
			health := strings.Fields(string(fixture.mustTool(t, nil, "check", fixture.state, fixture.generation)))
			for _, challenge := range []string{health[0], strings.Repeat("b", 64)} {
				conn, err := fixture.dial()
				if err != nil {
					t.Fatal(err)
				}
				if err := forwardproto.Send(conn, 'P', []byte(challenge)); err != nil {
					conn.Close()
					t.Fatal(err)
				}
				kind, proof, err := forwardproto.Receive(conn, 64)
				conn.Close()
				if err != nil || kind != 'P' || ((string(proof) == health[1]) != (challenge == health[0])) {
					t.Fatalf("generation challenge: %c, %q, %v", kind, proof, err)
				}
			}
			conn, err := fixture.request("", "hold")
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			var descendant int
			for descendant == 0 {
				kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
				if err != nil {
					t.Fatal(err)
				}
				if kind == 'O' {
					descendant, err = strconv.Atoi(strings.TrimSpace(string(data)))
					if err != nil {
						t.Fatal(err)
					}
				}
			}
			if cause == "disconnect" {
				conn.Close()
			} else if cause == "retire" {
				fixture.mustTool(t, nil, "retire", fixture.state)
				if _, err := os.Stat(fixture.state); !os.IsNotExist(err) {
					t.Fatalf("state not retired: %v", err)
				}
			} else {
				data, err := os.ReadFile(fixture.pids)
				if err != nil {
					t.Fatal(err)
				}
				daemon, ssh := 0, 0
				if _, err := fmt.Sscan(string(data), &daemon, &ssh); err != nil {
					t.Fatal(err)
				}
				if cause == "service death" {
					err = syscall.Kill(daemon, syscall.SIGKILL)
				} else {
					err = syscall.Kill(ssh, syscall.SIGTERM)
				}
				if err != nil {
					t.Fatal(err)
				}
			}
			if cause != "disconnect" {
				for {
					kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk)
					if kind == 'X' {
						t.Fatal("interruption reported as a command exit")
					}
					if err != nil {
						if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
							t.Fatal("interrupted connection did not close")
						}
						break
					}
				}
				waitFor(t, func() bool {
					_, err := fixture.tool(nil, "check", fixture.state, fixture.generation)
					return err != nil
				})
			}
			waitFor(t, func() bool {
				status, err := exec.Command("ps", "-p", strconv.Itoa(descendant), "-o", "stat=").Output()
				return err != nil || strings.HasPrefix(strings.TrimSpace(string(status)), "Z")
			})
		})
	}
}

func testPinnedDirectory(project string) error {
	var info syscall.Stat_t
	if err := syscall.Stat(project, &info); err != nil {
		return err
	}
	saved := manifest{Project: []byte(project), Identity: identity{uint64(info.Dev), uint64(info.Ino)}}
	if err := saved.enterProject("sub"); err != nil {
		return err
	}
	if err := os.Rename(project+"/sub", project+"/moved"); err != nil {
		return err
	}
	if err := os.Mkdir(project+"/sub", 0755); err != nil {
		return err
	}
	if err := os.WriteFile(project+"/sub/marker", []byte("replacement"), 0644); err != nil {
		return err
	}
	return syscall.Exec("/bin/cat", []string{"cat", "marker"}, os.Environ())
}

func TestPinnedDirectorySurvivesReplacement(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(root+"/sub", 0755); err != nil {
		t.Fatal(err)
	}
	writeFixture(t, root+"/sub/marker", "original", 0644)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	got, err := exec.Command(self, "test-pinned-directory", root).CombinedOutput()
	if err != nil || string(got) != "original" {
		t.Fatalf("pinned directory: %q, %v", got, err)
	}
}

func TestForwardingRuntimeLocations(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	install := filepath.Join(root, "install")
	project := filepath.Join(root, "project")
	runtime := filepath.Join(project, "runtime")
	for _, directory := range []string{filepath.Join(install, "container"), filepath.Join(runtime, "bin")} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(runtime, filepath.Join(install, "container", "runtime")); err != nil {
		t.Fatal(err)
	}
	if _, err := prepare(project, install, nil, 0022); err == nil || !strings.Contains(err.Error(), "outside the forwarded project") {
		t.Fatalf("project-writable runtime: %v", err)
	}
	saved := manifest{RuntimePaths: [][]byte{[]byte(runtime)}}
	if err := saved.checkStorage(project); err == nil || !strings.Contains(err.Error(), "container-writable mount") {
		t.Fatalf("mount-writable runtime: %v", err)
	}
}

// Podman on macOS reports volume paths inside its virtual machine, which need
// not exist on the host. Storage checks resolve the existing host prefix,
// including symlinks, keep the rest of the path, and refuse a dangling link.
func TestMountSourceOutsideHost(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	tail := filepath.Join("machine", "volumes", "home", "_data")
	if got, err := resolveMountSource(filepath.Join(link, tail)); err != nil || got != filepath.Join(root, tail) {
		t.Fatalf("virtual machine path: %q, %v", got, err)
	}
	saved := manifest{SSH: []byte("/bin/sh"),
		Executables: map[string][]byte{"tool": []byte(filepath.Join(root, "machine", "bin", "tool"))}}
	if err := saved.checkStorage(filepath.Join(link, tail)); err != nil {
		t.Fatalf("virtual machine volume without host programs: %v", err)
	}
	// Only the resolved symlink shows that this missing directory covers the program.
	if err := saved.checkStorage(filepath.Join(link, "machine")); err == nil || !strings.Contains(err.Error(), "container-writable mount") {
		t.Fatalf("host program under a resolved virtual machine path: %v", err)
	}
	dangling := filepath.Join(root, "dangling")
	if err := os.Symlink(filepath.Join(root, "missing"), dangling); err != nil {
		t.Fatal(err)
	}
	if err := saved.checkStorage(filepath.Join(dangling, "_data")); err == nil || !strings.Contains(err.Error(), "could not resolve") {
		t.Fatalf("dangling link in a mount source: %v", err)
	}
}
