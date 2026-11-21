//go:build darwin

package forwarding

import "golang.org/x/sys/unix"

// awaitExit blocks until the process exits and leaves it unreaped, so its ID
// and the process group ID it leads stay reserved until the caller reaps it.
// kqueue reports exit separately from reaping. Only the caller reaps this
// child, so a registration that finds no process means it already exited.
func awaitExit(pid int) error {
	kq, err := unix.Kqueue()
	if err != nil {
		return err
	}
	defer unix.Close(kq)
	var change unix.Kevent_t
	unix.SetKevent(&change, pid, unix.EVFILT_PROC, unix.EV_ADD|unix.EV_ONESHOT)
	change.Fflags = unix.NOTE_EXIT
	events := make([]unix.Kevent_t, 1)
	for {
		n, err := unix.Kevent(kq, []unix.Kevent_t{change}, events, nil)
		switch {
		case err == unix.EINTR:
			continue
		case err == unix.ESRCH:
			return nil
		case err != nil:
			return err
		case n == 1 && events[0].Flags&unix.EV_ERROR != 0:
			if errno := unix.Errno(events[0].Data); errno != unix.ESRCH {
				return errno
			}
			return nil
		case n == 1:
			return nil
		}
	}
}
