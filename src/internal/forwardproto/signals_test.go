//go:build linux || darwin

package forwardproto

import (
	"runtime"
	"syscall"
	"testing"
)

func TestPortableSignalNames(t *testing.T) {
	for name, native := range map[string]syscall.Signal{"SIGINT": syscall.SIGINT, "SIGUSR1": syscall.SIGUSR1, "SIGUSR2": syscall.SIGUSR2, "SIGABRT": syscall.SIGABRT, "SIGTERM": syscall.SIGTERM, "SIGHUP": syscall.SIGHUP} {
		if got := SignalName(native); got != name {
			t.Errorf("signal %d mapped to %q, want %q", native, got, name)
		}
		if got := SignalNumber(name); got != native {
			t.Errorf("%s mapped to %d, want %d", name, got, native)
		}
	}
	if runtime.GOOS == "linux" {
		if SignalNumber("SIGEMT") != 0 {
			t.Fatal("SIGEMT must have no Linux equivalent")
		}
		for n := syscall.Signal(32); n <= 64; n++ {
			if SignalNumber(SignalName(n)) != n {
				t.Errorf("real-time signal %d not preserved", n)
			}
		}
	}
}
