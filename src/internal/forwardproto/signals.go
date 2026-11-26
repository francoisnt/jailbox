//go:build linux || darwin

package forwardproto

import (
	"runtime"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// Standard signals use their names, not the host's native numbering.
// Linux-specific real-time signals use their offset from kernel RTMIN.
func SignalName(sig syscall.Signal) string {
	if name := unix.SignalName(sig); name != "" {
		return name
	}
	if runtime.GOOS == "linux" && sig >= 32 && sig <= 64 {
		return "SIGRTMIN+" + strconv.Itoa(int(sig)-32)
	}
	return "UNKNOWN"
}

func SignalNumber(name string) syscall.Signal {
	if sig := unix.SignalNum(name); sig != 0 {
		return sig
	}
	if offset, ok := strings.CutPrefix(name, "SIGRTMIN+"); ok && runtime.GOOS == "linux" {
		n, err := strconv.Atoi(offset)
		if err == nil && n >= 0 && n <= 32 && strconv.Itoa(n) == offset {
			return syscall.Signal(32 + n)
		}
	}
	return 0
}
