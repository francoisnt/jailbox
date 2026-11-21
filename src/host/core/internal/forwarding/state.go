package forwarding

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/francoisnt/jailbox/internal/buildversion"
	"github.com/francoisnt/jailbox/internal/forwardproto"
	"golang.org/x/sys/unix"
)

const (
	controlSocket = "control.sock"
	requestSocket = "requests.sock"
	lockFile      = "lock"
	manifestFile  = "manifest"
	policyFile    = "policy"
	logFile       = "ssh.log"
)

var generationID = regexp.MustCompile(`^[0-9a-f]{64}$`)

type manifest struct {
	// Paths can contain arbitrary non-NUL bytes. JSON encodes these as Base64.
	Project           []byte            `json:"project"`
	Identity          identity          `json:"identity"`
	Executables       map[string][]byte `json:"executables"`
	Hash              string            `json:"hash"`
	ProbeKey          []byte            `json:"probe_key"`
	SSH               []byte            `json:"ssh"`
	RuntimePaths      [][]byte          `json:"runtime_paths"`
	Umask             int               `json:"umask"`
	HiddenDirectories []identity        `json:"hidden_directories"`
}

func hash(contents []byte) string {
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}

func decodePolicy(frame string) ([]byte, error) {
	frame = strings.TrimSpace(frame)
	if len(frame) > base64.StdEncoding.EncodedLen(policyLimit) || strings.ContainsAny(frame, "\r\n") {
		return nil, errors.New("invalid host forwarding policy snapshot")
	}
	return base64.StdEncoding.DecodeString(frame)
}

func randomKey() []byte {
	key := make([]byte, 32)
	rand.Read(key)
	return key
}

func prepare(project, install string, contents []byte, umask int) (manifest, error) {
	self, err := os.Executable()
	if err != nil {
		return manifest{}, err
	}
	program, err := filepath.EvalSymlinks(self)
	if err != nil {
		return manifest{}, err
	}
	runtime, err := filepath.EvalSymlinks(filepath.Join(install, "container/runtime"))
	if err != nil {
		return manifest{}, err
	}
	helpersDir, err := filepath.EvalSymlinks(filepath.Join(runtime, "bin"))
	if err != nil {
		return manifest{}, err
	}
	runtimePaths := [][]byte{[]byte(install), []byte(program), []byte(runtime), []byte(helpersDir)}
	for _, path := range runtimePaths {
		if inTree(string(path), project) {
			return manifest{}, errors.New("the jailbox installation must be outside the forwarded project tree")
		}
	}
	// Container commands jailbox itself runs on PATH. Forwarding shims for
	// these names would replace them, so policies cannot use them.
	required := "awk bash chmod curl find grep id mktemp mv rm sh ssh sshd ssh-keygen stat tar wget"
	reserved := make(map[string]bool)
	for _, name := range strings.Fields(required) {
		reserved[name] = true
	}
	helpers, err := os.ReadDir(helpersDir)
	if err != nil {
		return manifest{}, err
	}
	for _, helper := range helpers {
		reserved[helper.Name()] = true
	}
	rules, err := compilePolicy(string(contents), reserved)
	if err != nil {
		return manifest{}, err
	}
	executables := make(map[string][]byte, len(rules))
	for name := range rules {
		_, path, err := locateExecutable(name, project)
		if err != nil {
			return manifest{}, err
		}
		executables[name] = []byte(path)
	}
	ssh, _, err := locateExecutable("ssh", project)
	if err != nil {
		return manifest{}, err
	}
	fd, err := unix.Open(project, dirFlags, 0)
	if err != nil {
		return manifest{}, fmt.Errorf("cannot pin the host project root: %w", err)
	}
	defer unix.Close(fd)
	id, err := directoryID(fd)
	return manifest{
		Project: []byte(project), Identity: id, Executables: executables,
		Hash: hash(contents), ProbeKey: randomKey(), SSH: []byte(ssh),
		RuntimePaths: runtimePaths, Umask: umask,
	}, err
}

func publish(project, state, server, expectedHash string, hidden []string, contents []byte, prepared []byte) error {
	var saved manifest
	if err := json.Unmarshal(prepared, &saved); err != nil {
		return err
	}
	if hash(contents) != expectedHash {
		return errors.New("inconsistent host forwarding policy snapshot")
	}
	if saved.Hash != expectedHash || string(saved.Project) != project {
		return errors.New("inconsistent host forwarding policy preparation")
	}
	var err error
	saved.HiddenDirectories, err = saved.hiddenIdentities(hidden)
	if err != nil {
		return err
	}
	text, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	// Launch rollback owns the state and the server directory if writing
	// either one fails. The endpoint is only started after publication.
	if err := os.Mkdir(state, 0700); err != nil {
		return err
	}
	for name, data := range map[string][]byte{manifestFile: text, policyFile: contents} {
		if err := os.WriteFile(filepath.Join(state, name), data, 0600); err != nil {
			return err
		}
	}
	shims := filepath.Join(server, "host-commands")
	if err := os.Mkdir(shims, 0700); err != nil {
		return err
	}
	for name := range saved.Executables {
		if !commandName.MatchString(name) {
			return errors.New("invalid executable name in forwarding preparation")
		}
		// Both the version and executable name have shell-safe grammars.
		path := filepath.Join(shims, name)
		shim := fmt.Sprintf("#!/bin/bash\nexec %s %s forward %s \"$@\"\n", forwardproto.ContainerHelper, buildversion.Version, name)
		if err := os.WriteFile(path, []byte(shim), 0700); err != nil {
			return err
		}
		if err := os.Chmod(path, 0755); err != nil {
			return err
		}
	}
	return os.Chmod(shims, 0755)
}

func loadManifest() (manifest, error) {
	var saved manifest
	data, err := os.ReadFile(manifestFile)
	if err != nil {
		return saved, err
	}
	err = json.Unmarshal(data, &saved)
	return saved, err
}

func names() (string, error) {
	saved, err := loadManifest()
	if err != nil {
		return "", err
	}
	var names []string
	for name := range saved.Executables {
		names = append(names, name)
	}
	sort.Strings(names)
	return strings.Join(names, " "), nil
}

// A remote engine can report a VM path whose tail does not exist on the host.
// Resolve every existing component, including symlinks in the host prefix.
func resolveMountSource(path string) (string, error) {
	root, err := filepath.EvalSymlinks(path)
	if !os.IsNotExist(err) {
		return root, err
	}
	if _, statErr := os.Lstat(path); !os.IsNotExist(statErr) {
		return "", fmt.Errorf("could not resolve mount source %s: %w", path, err)
	}
	parent := filepath.Dir(path)
	if parent == path {
		return "", err
	}
	root, err = resolveMountSource(parent)
	if err != nil {
		return "", err
	}
	return filepath.Join(root, filepath.Base(path)), nil
}

func (saved manifest) checkStorage(source string) error {
	if !filepath.IsAbs(source) || strings.ContainsFunc(source, func(r rune) bool { return r < 32 }) {
		return errors.New("unknown writable mount source for host forwarding")
	}
	root, err := resolveMountSource(source)
	if err != nil {
		return fmt.Errorf("could not resolve writable mount source for host forwarding: %w", err)
	}
	for name, path := range saved.Executables {
		if inTree(string(path), root) {
			return fmt.Errorf("host executable %s resolves inside a container-writable mount", name)
		}
	}
	for _, path := range saved.RuntimePaths {
		if inTree(string(path), root) {
			return errors.New("the jailbox installation lies inside a container-writable mount")
		}
	}
	ssh, err := filepath.EvalSymlinks(string(saved.SSH))
	if err != nil {
		return err
	}
	if inTree(ssh, root) || inTree(string(saved.SSH), root) {
		return errors.New("the host ssh helper lies inside a container-writable mount")
	}
	return nil
}

func (saved manifest) checkMounts(raw []byte) error {
	var mounts []struct {
		Writable *bool `json:"RW"`
		Type     string
		Source   string
	}
	if err := json.Unmarshal(raw, &mounts); err != nil {
		return err
	}
	hasHome := false
	for _, mount := range mounts {
		if mount.Writable == nil {
			return errors.New("invalid mount inspection for host forwarding")
		}
		if *mount.Writable {
			hasHome = hasHome || mount.Type == "volume"
			if err := saved.checkStorage(mount.Source); err != nil {
				return err
			}
		}
	}
	if !hasHome {
		return errors.New("could not establish sandbox home storage for host forwarding")
	}
	return nil
}

func inspectState(state string) error {
	var info unix.Stat_t
	if err := unix.Lstat(state, &info); err != nil {
		return err
	}
	if info.Mode != unix.S_IFDIR|0700 || info.Uid != uint32(os.Getuid()) {
		return errors.New("unsafe host forwarding state directory")
	}
	entries, err := os.ReadDir(state)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		want := uint32(unix.S_IFREG)
		switch entry.Name() {
		case controlSocket, requestSocket:
			want = unix.S_IFSOCK
		case lockFile, manifestFile, policyFile, logFile:
		default:
			return errors.New("unsafe file in host forwarding state")
		}
		if err := unix.Lstat(filepath.Join(state, entry.Name()), &info); err != nil {
			return err
		}
		if uint32(info.Mode)&unix.S_IFMT != want || info.Uid != uint32(os.Getuid()) || info.Mode&0077 != 0 {
			return errors.New("unsafe file in host forwarding state")
		}
	}
	// Only one-shot helpers enter state here. Service and workers inherit
	// the directory so their Unix socket paths stay short on all platforms.
	return os.Chdir(state)
}

func lockState(create bool) (*os.File, bool, error) {
	flags := unix.O_RDWR | unix.O_NOFOLLOW | unix.O_CLOEXEC
	if create {
		flags |= unix.O_CREAT
	}
	fd, err := unix.Open(lockFile, flags, 0600)
	if err == unix.ENOENT && !create {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, err
	}
	file := os.NewFile(uintptr(fd), lockFile)
	err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
	if err == unix.EWOULDBLOCK {
		return file, false, nil
	}
	if err != nil {
		file.Close()
		return nil, false, err
	}
	return file, true, nil
}

func controlRequest(kind byte, timeout time.Duration) (byte, []byte, error) {
	conn, err := net.DialTimeout("unix", controlSocket, timeout)
	if err != nil {
		return 0, nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return 0, nil, err
	}
	if err := forwardproto.Send(conn, kind, nil); err != nil {
		return 0, nil, err
	}
	return forwardproto.Receive(conn, 64)
}

func retire(state string) error {
	if err := inspectState(state); err != nil {
		return err
	}
	deadline := time.Now().Add(6 * time.Second)
	requested := false
	for {
		lock, idle, err := lockState(false)
		if err != nil {
			return err
		}
		if idle {
			if lock != nil {
				defer lock.Close()
			}
			entries, err := os.ReadDir(".")
			if err != nil {
				return err
			}
			for _, entry := range entries {
				if err := os.Remove(entry.Name()); err != nil {
					return err
				}
			}
			if err := os.Chdir(".."); err != nil {
				return err
			}
			return os.Remove(state)
		}
		lock.Close()
		if time.Now().After(deadline) {
			return errors.New("could not verify shutdown of the owned host forwarding service")
		}
		if !requested {
			kind, detail, err := controlRequest('S', 3*time.Second)
			if err == nil && kind == 'F' {
				return errors.New(string(detail))
			}
			requested = err == nil && kind == 'S' && len(detail) == 0
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (saved manifest) probeResponse(generation string, challenge []byte) []byte {
	mac := hmac.New(sha256.New, saved.ProbeKey)
	mac.Write([]byte(generation))
	mac.Write(challenge)
	return []byte(hex.EncodeToString(mac.Sum(nil)))
}

func check(state, generation string) (string, error) {
	if err := inspectState(state); err != nil {
		return "", err
	}
	lock, idle, err := lockState(false)
	if err != nil {
		return "", err
	}
	if lock != nil {
		lock.Close()
	}
	if !idle {
		kind, detail, err := controlRequest('H', time.Second)
		if err == nil && kind == 'H' && string(detail) == generation {
			saved, err := loadManifest()
			if err != nil {
				return "", err
			}
			challenge := hex.EncodeToString(randomKey())
			return challenge + " " + string(saved.probeResponse(generation, []byte(challenge))), nil
		}
	}
	return "", errors.New("host forwarding service is unavailable or belongs to a different container")
}
