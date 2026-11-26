//go:build linux

package forwardclient

import (
	"os"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

func terminal(file *os.File) bool {
	_, err := unix.IoctlGetTermios(int(file.Fd()), unix.TCGETS)
	return err == nil
}

// The Go runtime installs handlers for fatal signals (including signals
// which would otherwise be ignored by it). Restore the kernel's default
// action and deliver to this unblocked thread, not another Go thread.
// Both supported Linux architectures have the same kernel sigaction layout.
func terminate(sig syscall.Signal) {
	if sig < 1 || sig > 64 {
		return
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if sig != unix.SIGKILL {
		var action [4]uint64
		_, _, err := unix.RawSyscall6(unix.SYS_RT_SIGACTION, uintptr(sig), uintptr(unsafe.Pointer(&action)), 0, 8, 0, 0)
		if err != 0 {
			return
		}
	}
	mask := uint64(1) << (sig - 1)
	_, _, err := unix.RawSyscall6(unix.SYS_RT_SIGPROCMASK, unix.SIG_UNBLOCK, uintptr(unsafe.Pointer(&mask)), 0, 8, 0, 0)
	if err != 0 {
		return
	}
	_ = unix.Tgkill(os.Getpid(), unix.Gettid(), sig)
}
