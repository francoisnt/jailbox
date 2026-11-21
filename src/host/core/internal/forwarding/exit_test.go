package forwarding

import (
	"os/exec"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// awaitExit must report exit without reaping: the exited process keeps its
// ID until Wait, so a group signal sent in between cannot reach another group.
func TestAwaitExitLeavesProcessUnreaped(t *testing.T) {
	for _, delay := range []time.Duration{0, 100 * time.Millisecond} {
		command := exec.Command("/bin/sh", "-c", "exit 7")
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		// With a delay, the process has already exited before the watch starts.
		time.Sleep(delay)
		if err := awaitExit(command.Process.Pid); err != nil {
			t.Fatalf("delay %v: %v", delay, err)
		}
		if err := unix.Kill(command.Process.Pid, 0); err != nil {
			t.Fatalf("delay %v: exited process was reaped early: %v", delay, err)
		}
		if err := command.Wait(); command.ProcessState == nil || command.ProcessState.ExitCode() != 7 {
			t.Fatalf("delay %v: wait after exit: %v", delay, err)
		}
	}
}
