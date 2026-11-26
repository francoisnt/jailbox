// Package forwardproto carries binary streams over the forwarding socket.
package forwardproto

import (
	"encoding/binary"
	"errors"
	"io"
)

const (
	Socket          = "/run/jailbox-forward.sock"
	Project         = "/home/jailbox/project"
	ContainerHelper = "/usr/local/lib/jailbox/jailbox-container"
	Chunk           = 65536
	DirectoryLimit  = 4096
)

// D and A carry request metadata. C grants credit for one I chunk.
// An empty I ends stdin. O and E carry output, X is a command exit, and
// S announces a started command before any credit or output. G delivers a
// signal by name, independently of stdin. X carries a single status byte or
// a signal name. F refuses a request; L refuses with permission to run locally.
// P is a readiness challenge or reply.
func Receive(r io.Reader, limit uint32) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	size := binary.BigEndian.Uint32(header[1:])
	if size > limit {
		return 0, nil, errors.New("oversized forwarding message")
	}
	payload := make([]byte, size)
	_, err := io.ReadFull(r, payload)
	return header[0], payload, err
}

func Send(w io.Writer, kind byte, payload []byte) error {
	var header [5]byte
	header[0] = kind
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}
