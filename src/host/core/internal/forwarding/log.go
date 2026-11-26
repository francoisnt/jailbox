package forwarding

import (
	"bytes"
	"encoding/csv"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

const matchLogFile = "policy-matches.csv"
const matchLogLimit = 1 << 20

// Serialize replacement of the bounded log using a separate, stable lock.
// A failed read, write or rename leaves the published log alone.
func logMatch(state, cwd string, args []string, matched bool) {
	lockPath := filepath.Join(state, "policy-matches.lock")
	fd, err := unix.Open(lockPath, unix.O_RDWR|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0600)
	if err != nil {
		return
	}
	defer unix.Close(fd)
	var info unix.Stat_t
	if err := unix.Fstat(fd, &info); err != nil || info.Mode&unix.S_IFMT != unix.S_IFREG || info.Mode&0077 != 0 || info.Uid != uint32(os.Getuid()) {
		return
	}
	deadline := time.Now().Add(50 * time.Millisecond)
	for {
		err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			break
		}
		if err != unix.EWOULDBLOCK || time.Now().After(deadline) {
			return
		}
		time.Sleep(5 * time.Millisecond)
		if !time.Now().Before(deadline) {
			return
		}
	}
	path := filepath.Join(state, matchLogFile)
	var rows []byte
	oldFD, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err == nil {
		old := os.NewFile(uintptr(oldFD), path)
		if err := unix.Fstat(oldFD, &info); err != nil || info.Mode&unix.S_IFMT != unix.S_IFREG || info.Mode&0077 != 0 || info.Uid != uint32(os.Getuid()) {
			old.Close()
			return
		}
		rows, err = io.ReadAll(io.LimitReader(old, matchLogLimit+1))
		old.Close()
		if err != nil || len(rows) > matchLogLimit {
			return
		}
	} else if !os.IsNotExist(err) {
		return
	}
	header := []byte("timestamp,cwd,command,match\n")
	if len(rows) == 0 {
		rows = header
	}
	if !bytes.HasPrefix(rows, header) || rows[len(rows)-1] != '\n' {
		return
	}
	var command []string
	for _, arg := range args {
		command = append(command, strconv.Quote(arg))
	}
	match := "unmatched"
	if matched {
		match = "matched"
	}
	var record bytes.Buffer
	writer := csv.NewWriter(&record)
	if err := writer.Write([]string{time.Now().UTC().Format(time.RFC3339Nano), cwd, strings.Join(command, " "), match}); err != nil {
		return
	}
	writer.Flush()
	if writer.Error() != nil || len(header)+record.Len() > matchLogLimit {
		return
	}
	data := rows[len(header):]
	if len(rows)+record.Len() > matchLogLimit {
		reader := csv.NewReader(bytes.NewReader(data))
		for len(header)+len(data)-int(reader.InputOffset())+record.Len() > matchLogLimit {
			if _, err := reader.Read(); err != nil {
				return
			}
		}
		data = data[reader.InputOffset():]
	}
	// There is only one writer under the lock. A fixed temporary pathname
	// bounds leftover storage even if the worker was killed during a write.
	temporary := path + ".tmp"
	if err := os.Remove(temporary); err != nil && !os.IsNotExist(err) {
		return
	}
	temp, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return
	}
	defer os.Remove(temp.Name())
	_, err = temp.Write(header)
	if err == nil {
		_, err = temp.Write(data)
	}
	if err == nil {
		_, err = temp.Write(record.Bytes())
	}
	closeErr := temp.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(temp.Name(), path)
	}
}
