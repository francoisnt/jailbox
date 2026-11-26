package forwarding

import (
	"bytes"
	"encoding/csv"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func readMatchLog(t *testing.T, dir string) ([]byte, [][]string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, matchLogFile))
	if err != nil {
		t.Fatal(err)
	}
	records, err := csv.NewReader(bytes.NewReader(data)).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	return data, records
}

func TestMatchLogRecords(t *testing.T) {
	dir := t.TempDir()
	args := []string{"cmd", "", "two words", "a\nb\xff", `"\`}
	// Repeated invocations create separate records; concurrent writers may
	// legitimately skip a record if their bounded lock wait expires.
	logMatch(dir, "sub,dir\n", args, true)
	logMatch(dir, "sub,dir\n", args, true)
	var wg sync.WaitGroup
	for i := range 8 {
		wg.Go(func() { logMatch(dir, "sub,dir\n", args, i%2 == 0) })
	}
	wg.Wait()
	data, records := readMatchLog(t, dir)
	if len(records) < 4 || len(records) > 11 || string(data[:len("timestamp,cwd,command,match\n")]) != "timestamp,cwd,command,match\n" {
		t.Fatalf("rows: %q", records)
	}
	var quoted []string
	for _, arg := range args {
		quoted = append(quoted, strconv.Quote(arg))
	}
	for _, row := range records[1:] {
		if timestamp, err := time.Parse(time.RFC3339Nano, row[0]); err != nil || timestamp.Location() != time.UTC || row[1] != "sub,dir\n" || row[2] != strings.Join(quoted, " ") || (row[3] != "matched" && row[3] != "unmatched") {
			t.Errorf("row: %#v", row)
		}
	}
	for _, name := range []string{matchLogFile, "policy-matches.lock"} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.Mode().Perm() != 0600 {
			t.Fatalf("mode %s: %v, %v", name, info, err)
		}
	}
}

func TestMatchLogBoundAndFailures(t *testing.T) {
	dir := t.TempDir()
	large := strings.Repeat("x", matchLogLimit/3)
	for _, name := range []string{"oldest", "middle", "latest", "newest"} {
		logMatch(dir, "", []string{name, large}, true)
	}
	before, rows := readMatchLog(t, dir)
	if len(before) > matchLogLimit || len(rows) != 3 || !strings.HasPrefix(rows[1][2], `"latest"`) || !strings.HasPrefix(rows[2][2], `"newest"`) {
		t.Fatal("incorrect trimming")
	}
	logMatch(dir, "", []string{strings.Repeat("x", matchLogLimit)}, true)
	after, _ := readMatchLog(t, dir)
	if !bytes.Equal(before, after) {
		t.Fatal("oversized record changed log")
	}
	lock, err := os.OpenFile(filepath.Join(dir, "policy-matches.lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	logMatch(dir, "", []string{"blocked"}, false)
	if time.Since(start) > time.Second {
		t.Fatal("log writer waited too long")
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	after, _ = readMatchLog(t, dir)
	if !bytes.Equal(before, after) {
		t.Fatal("stalled writer changed log")
	}
	if os.Getuid() == 0 {
		t.Skip("root ignores directory write permissions")
	}
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0700)
	logMatch(dir, "", []string{"write failure"}, false)
	logMatch(dir, "", []string{"trimming failure", large}, false)
	after, _ = readMatchLog(t, dir)
	if !bytes.Equal(before, after) {
		t.Fatal("failed write changed log")
	}
}
