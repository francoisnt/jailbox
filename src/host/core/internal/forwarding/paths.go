package forwarding

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

var errHiddenDirectory = errors.New("working directory is hidden by HIDDEN_PATHS")

const dirFlags = unix.O_RDONLY | unix.O_DIRECTORY | unix.O_NOFOLLOW | unix.O_CLOEXEC

type identity [2]uint64

func fileID(info *unix.Stat_t) identity {
	return identity{uint64(info.Dev), uint64(info.Ino)}
}

func directoryID(fd int) (identity, error) {
	var info unix.Stat_t
	err := unix.Fstat(fd, &info)
	return fileID(&info), err
}

func validComponent(component string) bool {
	return component != "" && component != "." && component != ".." && !strings.ContainsRune(component, 0)
}

func openDirectory(root int, relative string, hidden map[identity]bool) (int, error) {
	fd, err := unix.FcntlInt(uintptr(root), unix.F_DUPFD_CLOEXEC, 0)
	if err != nil || relative == "" {
		return fd, err
	}
	for _, component := range strings.Split(relative, "/") {
		if !validComponent(component) {
			unix.Close(fd)
			return -1, errors.New("invalid project-relative working directory or policy path")
		}
		child, err := unix.Openat(fd, component, dirFlags, 0)
		unix.Close(fd)
		if err != nil {
			return -1, err
		}
		fd = child
		if len(hidden) != 0 {
			id, err := directoryID(fd)
			if err != nil {
				unix.Close(fd)
				return -1, err
			}
			if hidden[id] {
				// Return the pinned directory itself, without inspecting descendants.
				return fd, errHiddenDirectory
			}
		}
	}
	return fd, nil
}

func capture(project, path string) ([]byte, error) {
	root, err := unix.Open(project, dirFlags, 0)
	if err != nil {
		return nil, err
	}
	defer unix.Close(root)
	parent, name := relativeParent(path)
	if name == "" || name == "." || name == ".." || filepath.IsAbs(path) {
		return nil, errors.New("invalid project-relative policy path")
	}
	dir, err := openDirectory(root, parent, nil)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dir)
	fd, err := unix.Openat(dir, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("HOST_COMMAND_POLICY must be a readable regular file")
	}
	contents, err := io.ReadAll(io.LimitReader(file, policyLimit+1))
	if err == nil && len(contents) > policyLimit {
		err = errors.New("HOST_COMMAND_POLICY exceeds 32768 bytes")
	}
	return contents, err
}

func relativeParent(path string) (string, string) {
	parent, name := filepath.Split(path)
	return strings.TrimSuffix(parent, "/"), name
}

func inTree(path, root string) bool {
	path, root = filepath.Clean(path), filepath.Clean(root)
	return path == root || strings.HasPrefix(path, strings.TrimSuffix(root, "/")+"/")
}

func locateExecutable(name, project string) (string, string, error) {
	path, err := exec.LookPath(name)
	if err != nil || !filepath.IsAbs(path) {
		return "", "", fmt.Errorf("host executable %s is unavailable on an absolute PATH entry", name)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", "", fmt.Errorf("host executable %s is unavailable: %w", name, err)
	}
	if inTree(path, project) || inTree(resolved, project) {
		return "", "", fmt.Errorf("host executable %s resolves inside the project tree", name)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || unix.Access(resolved, unix.X_OK) != nil {
		return "", "", fmt.Errorf("host executable %s is unavailable", name)
	}
	return path, resolved, nil
}

func (saved manifest) openProject() (int, error) {
	root, err := unix.Open(string(saved.Project), dirFlags, 0)
	if err != nil {
		return -1, err
	}
	id, err := directoryID(root)
	if err == nil && id != saved.Identity {
		err = errors.New("host project root has changed")
	}
	if err != nil {
		unix.Close(root)
		return -1, err
	}
	return root, nil
}

func (saved manifest) hiddenIdentities(paths []string) ([]identity, error) {
	root, err := saved.openProject()
	if err != nil {
		return nil, err
	}
	defer unix.Close(root)
	identities := make([]identity, 0, len(paths))
	for _, path := range paths {
		parent, name := relativeParent(path)
		if name == "" || name == "." || name == ".." || filepath.IsAbs(path) {
			return nil, errors.New("invalid project-relative hidden path")
		}
		dir, err := openDirectory(root, parent, nil)
		if err != nil {
			return nil, err
		}
		var info unix.Stat_t
		err = unix.Fstatat(dir, name, &info, unix.AT_SYMLINK_NOFOLLOW)
		unix.Close(dir)
		if err != nil {
			return nil, err
		}
		switch info.Mode & unix.S_IFMT {
		case unix.S_IFDIR:
			identities = append(identities, fileID(&info))
		case unix.S_IFREG:
		default:
			return nil, fmt.Errorf("HIDDEN_PATHS path changed before forwarding was published: %s", path)
		}
	}
	return identities, nil
}

func (saved manifest) enterProject(relative string) error {
	// The claimed path must be syntactically valid even if its contents are hidden.
	if relative != "" {
		for _, component := range strings.Split(relative, "/") {
			if !validComponent(component) {
				return errors.New("invalid project-relative working directory or policy path")
			}
		}
	}

	root, err := saved.openProject()
	if err != nil {
		return err
	}
	defer unix.Close(root)
	hidden := make(map[identity]bool, len(saved.HiddenDirectories))
	for _, id := range saved.HiddenDirectories {
		hidden[id] = true
	}
	dir, mappingErr := openDirectory(root, relative, hidden)
	if mappingErr != nil && !errors.Is(mappingErr, errHiddenDirectory) {
		return mappingErr
	}
	defer unix.Close(dir)
	if err := unix.Fchdir(dir); err != nil {
		return err
	}
	// Getwd must come from the OS. os.Getwd can return the inherited PWD.
	cwd, err := unix.Getwd()
	if err != nil {
		return err
	}
	if !inTree(cwd, string(saved.Project)) {
		return errors.New("working directory lies outside the host project")
	}
	return mappingErr
}
