//go:build linux

package forwarding

import "golang.org/x/sys/unix"

// awaitExit blocks until the process exits and leaves it unreaped, so its ID
// and the process group ID it leads stay reserved until the caller reaps it.
func awaitExit(pid int) error {
	for {
		var info unix.Siginfo
		err := unix.Waitid(unix.P_PID, pid, &info, unix.WEXITED|unix.WNOWAIT, nil)
		if err != unix.EINTR {
			return err
		}
	}
}
