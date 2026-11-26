//go:build darwin

package forwardclient

import (
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

func terminal(file *os.File) bool {
	_, err := unix.IoctlGetTermios(int(file.Fd()), unix.TIOCGETA)
	return err == nil
}

// The forwarding client ships only for Linux. Native Darwin tests exercise
// the stream and ordinary interrupt behavior without a container.
func terminate(sig syscall.Signal) {
	signal.Reset(sig)
	_ = syscall.Kill(os.Getpid(), sig)
	time.Sleep(100 * time.Millisecond)
}
