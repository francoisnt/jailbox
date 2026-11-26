package forwarding

import (
	"bytes"
	"encoding/base64"
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
		var err error
		if os.Args[2] == "request" && os.Getenv("FORWARDING_TEST_MATCH_TIMEOUT") == "1" {
			err = request(os.Args[3], time.Nanosecond)
		} else {
			err = Run(os.Args[2], os.Args[3:])
		}
		if err != nil {
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
	policy := "[forwarded-command]\nlog all\nallow stream\nallow args '' {{.*}} {{.*}}\n" +
		"allow directory {{.*}}\nallow hold\nallow wait\n" +
		"allow effect one\nallow effect {{.*}}\nallow terminal\n" +
		"allow first-line\nallow signals\nallow blocked-input\nallow survivor\nallow signal-exit {{[A-Z0-9]+}}\nallow status {{[0-9]+}}\n" +
		"[forwarded-command args]\ninsert 'inserted arg'\n" +
		"[forwarded-command disabled]\nfallback false\nlog unmatched\n" +
		"[forwarded-command silent]\nlog none\n" +
		"[forwarded-command status]\nlog unmatched\n" +
		"[settings-only]\nlog all\n"
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
	return fixture.requestArgs(directory, append([]string{"forwarded-command"}, args...))
}

func (fixture socketFixture) requestArgs(directory string, args []string) (net.Conn, error) {
	frame, err := argv.Encode("test forwarding request", args)
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
		case 'S':
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
	writeFixture(t, fixture.project+"/policy", "[forwarded-command]\nallow changed\n", 0644)
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
	if got := require("", nil, "args", "", "\xff\n'$x*", "hello world\n"); got != (execution{'X', "\x00", "inserted arg\x00\x00\xff\n'$x*\x00hello world\n\x00", ""}) {
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
	for _, args := range [][]string{{"effect", "one", "extra"}} {
		if got := require("", nil, args...); got.kind != 'L' {
			t.Fatalf("invalid request accepted: %#v", got)
		}
	}
	if _, err := os.Stat(fixture.project + "/forwarded-effect"); !os.IsNotExist(err) {
		t.Fatalf("invalid request had a host effect: %v", err)
	}
	if got := require("", nil, "effect", "one"); got.kind != 'X' {
		t.Fatalf("overlapping rules refused: %#v", got)
	}
	if err := os.Remove(fixture.project + "/forwarded-effect"); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(fixture.project+"/data", fixture.project+"/moved"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(fixture.project+"/data/hidden", 0755); err != nil {
		t.Fatal(err)
	}
	if got := require("moved/hidden/missing", nil, "directory", "marker"); got.kind != 'L' ||
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
	result, err = fixture.collect("", nil, "unmatched")
	if err != nil || result.kind != 'F' || !strings.Contains(result.result, "unavailable") {
		t.Fatalf("unavailable executable hidden by fallback: %#v, %v", result, err)
	}
	writeFixture(t, fixture.executable, "#!/nonexistent-test-interpreter\n", 0755)
	result, err = fixture.collect("", nil, "terminal")
	if err != nil || result.kind != 'F' || !strings.Contains(result.result, "could not start") {
		t.Fatalf("start failure: %#v %v", result, err)
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

func TestFallbackAndLogging(t *testing.T) {
	fixture := newSocketFixture(t)
	for _, tc := range []struct {
		cwd, arg string
		kind     byte
	}{
		{"", "unknown", 'L'}, {"", "disabled", 'F'}, {"", "silent", 'L'}, {"missing", "unknown", 'F'}, {"data/hidden/missing", "terminal", 'L'}, {"data/hidden/../other", "unknown", 'F'}, {"", "terminal", 'X'},
	} {
		got, err := fixture.collect(tc.cwd, nil, tc.arg)
		if err != nil || got.kind != tc.kind {
			t.Fatalf("%+v: %#v, %v", tc, got, err)
		}
	}
	if got, err := fixture.collect("", nil, "status", "130"); err != nil || got.kind != 'X' {
		t.Fatalf("matched log unmatched: %#v, %v", got, err)
	}
	// A settings-only command has no executable to resolve, but its direct
	// request still receives the configured match log and local refusal.
	conn, err := fixture.requestArgs("", []string{"settings-only"})
	if err != nil {
		t.Fatal(err)
	}
	kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk)
	conn.Close()
	if err != nil || kind != 'L' {
		t.Fatalf("settings-only request: %c %v", kind, err)
	}
	if _, err := os.Stat(filepath.Join(fixture.server, "host-commands", "settings-only")); !os.IsNotExist(err) {
		t.Fatalf("settings-only wrapper: %v", err)
	}
	maxArg := strings.Repeat("x", base64.StdEncoding.DecodedLen(argv.Limit)-len("forwarded-command")-len("args")-3)
	if got, err := fixture.collect("", nil, "args", maxArg); err != nil || got.kind != 'F' || !strings.Contains(got.result, "argument list too long") {
		t.Fatalf("unmatched insertion overflow: %c %s, %v", got.kind, got.result, err)
	}
	dir := filepath.Dir(fixture.state)
	before, rows := readMatchLog(t, dir)
	if len(rows) != 9 {
		t.Fatalf("log should omit silent command: %q", rows)
	}
	for i, want := range []string{"unmatched", "unmatched", "unmatched", "matched", "unmatched", "matched", "unmatched", "unmatched"} {
		if rows[i+1][3] != want {
			t.Fatalf("unexpected match log: %q", rows)
		}
	}
	lock, err := os.OpenFile(filepath.Join(dir, "policy-matches.lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	got, err := fixture.collect("", nil, "unknown")
	lock.Close()
	if err != nil || got.kind != 'L' {
		t.Fatalf("blocked log changed fallback: %#v %v", got, err)
	}
	blocked, _ := readMatchLog(t, dir)
	if !bytes.Equal(before, blocked) {
		t.Fatal("blocked writer changed log")
	}
	snapshot := filepath.Join(fixture.state, policyFile)
	writeFixture(t, snapshot, "[forwarded-command]\nallow terminal\n", 0600)
	got, err = fixture.collect("", nil, "terminal")
	if err != nil || got.kind != 'F' || !strings.Contains(got.result, "snapshot has changed") {
		t.Fatalf("changed snapshot: %#v, %v", got, err)
	}
	after, _ := readMatchLog(t, dir)
	if !bytes.Equal(before, after) {
		t.Fatal("changed snapshot logged")
	}
	fixture.mustTool(t, nil, "retire", fixture.state)
	after, _ = readMatchLog(t, dir)
	if !bytes.Equal(before, after) {
		t.Fatal("retirement removed policy match log")
	}
}

func TestForwardedSignals(t *testing.T) {
	fixture := newSocketFixture(t)
	for _, name := range []string{"SIGUSR1", "SIGABRT"} {
		got, err := fixture.collect("", nil, "signal-exit", name)
		if err != nil || got.kind != 'X' || got.result != name {
			t.Fatalf("signal termination: %#v, %v", got, err)
		}
	}
	got, err := fixture.collect("", nil, "status", "130")
	if err != nil || got.kind != 'X' || got.result != string([]byte{130}) {
		t.Fatalf("numeric exit: %#v, %v", got, err)
	}
	conn, err := fixture.request("", "signals")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var out strings.Builder
	var credited bool
	readUntil := func(want string) {
		t.Helper()
		for !strings.Contains(out.String(), want) {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				t.Fatal(err)
			}
			switch kind {
			case 'S':
			case 'C':
				credited = true
			case 'O':
				out.Write(data)
			default:
				t.Fatalf("unexpected response %c: %q", kind, data)
			}
		}
	}
	readUntil("ready\n")
	for _, name := range []string{"SIGINT", "SIGTERM", "SIGHUP", "SIGINT"} {
		out.Reset()
		if err := forwardproto.Send(conn, 'G', []byte(name)); err != nil {
			t.Fatal(err)
		}
		readUntil(name + "\n")
	}
	for !credited {
		kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil || kind != 'C' {
			t.Fatalf("expected stdin credit: %c, %v", kind, err)
		}
		credited = true
	}
	if err := forwardproto.Send(conn, 'I', []byte("input\n")); err != nil {
		t.Fatal(err)
	}
	kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk)
	if err != nil || kind != 'C' {
		t.Fatalf("expected second credit: %c, %v", kind, err)
	}
	if err := forwardproto.Send(conn, 'I', nil); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	readUntil("input\n")
	if err := forwardproto.Send(conn, 'G', []byte("SIGTERM")); err != nil {
		t.Fatal(err)
	}
	readUntil("SIGTERM\n")
	kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
	if err != nil || kind != 'X' || len(data) != 1 || data[0] != 37 {
		t.Fatalf("exit after signals: %c %q %v", kind, data, err)
	}
}

func TestSignalMessageTiming(t *testing.T) {
	fixture := newSocketFixture(t)
	for _, tc := range []struct {
		signal string
		kind   byte
		result string
	}{
		{"SIGTERM", 'X', "SIGTERM"}, {"SIGUSR1", 0, ""},
	} {
		// Queue a signal with metadata, before waiting for the start message.
		conn, err := fixture.request("", "wait")
		if err != nil {
			t.Fatal(err)
		}
		if err := forwardproto.Send(conn, 'G', []byte(tc.signal)); err != nil {
			t.Fatal(err)
		}
		kind, _, err := forwardproto.Receive(conn, forwardproto.Chunk)
		if err != nil || kind != 'S' {
			t.Fatalf("signal affected pre-execution: %c, %v", kind, err)
		}
		for {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				if tc.kind != 0 {
					t.Fatalf("lost signal exit: %v", err)
				}
				if e, ok := err.(net.Error); ok && e.Timeout() {
					t.Fatal("invalid signal did not close request")
				}
				break
			}
			if kind == 'X' || kind == 'F' {
				if kind != tc.kind || string(data) != tc.result {
					t.Fatalf("signal response: %c %q", kind, data)
				}
				break
			}
		}
		conn.Close()
	}
}

func TestSignalsIndependentOfInputAndOutput(t *testing.T) {
	fixture := newSocketFixture(t)
	t.Run("blocked stdin", func(t *testing.T) {
		conn, err := fixture.request("", "blocked-input")
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		var output bytes.Buffer
		credited := false
		for !credited || output.String() != "ready\n" {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				t.Fatal(err)
			}
			switch kind {
			case 'S':
			case 'C':
				credited = true
			case 'O':
				output.Write(data)
			default:
				t.Fatalf("unexpected %c %q", kind, data)
			}
		}
		payload := bytes.Repeat([]byte{0, 0xff, 'a', '\n'}, forwardproto.Chunk/4)
		if err := forwardproto.Send(conn, 'I', payload); err != nil {
			t.Fatal(err)
		}
		if err := forwardproto.Send(conn, 'G', []byte("SIGINT")); err != nil {
			t.Fatal(err)
		}
		for {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				t.Fatal(err)
			}
			switch kind {
			case 'C':
				if err := forwardproto.Send(conn, 'I', nil); err != nil {
					t.Fatal(err)
				}
			case 'O':
				output.Write(data)
			case 'X':
				want := append([]byte("ready\nreleased\n"), payload...)
				if !bytes.Equal(output.Bytes(), want) || !bytes.Equal(data, []byte{0}) {
					t.Fatal("signal or data lost while stdin blocked")
				}
				return
			default:
				t.Fatalf("unexpected %c %q", kind, data)
			}
		}
	})
	t.Run("surviving group", func(t *testing.T) {
		conn, err := fixture.request("", "survivor")
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		var output strings.Builder
		for !strings.Contains(output.String(), "descendant ready\n") {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				t.Fatal(err)
			}
			if kind == 'O' {
				output.Write(data)
			}
		}
		if err := forwardproto.Send(conn, 'G', []byte("SIGTERM")); err != nil {
			t.Fatal(err)
		}
		for {
			kind, data, err := forwardproto.Receive(conn, forwardproto.Chunk)
			if err != nil {
				t.Fatal(err)
			}
			if kind == 'O' {
				output.Write(data)
			}
			if kind == 'X' {
				if !strings.Contains(output.String(), "descendant received signal\n") || !bytes.Equal(data, []byte{23}) {
					t.Fatalf("wrong output or exit: %q %q", output.String(), data)
				}
				break
			}
		}
	})
}

func TestMatchingTimeoutNotLogged(t *testing.T) {
	t.Setenv("FORWARDING_TEST_MATCH_TIMEOUT", "1")
	fixture := newSocketFixture(t)
	got, err := fixture.collect("", nil, "terminal")
	if err != nil || got.kind != 'F' || !strings.Contains(got.result, "timed out") {
		t.Fatalf("matching timeout: %#v %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(fixture.state), matchLogFile)); !os.IsNotExist(err) {
		t.Fatalf("timed out request logged: %v", err)
	}
}
