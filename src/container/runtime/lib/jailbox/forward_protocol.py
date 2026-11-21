"""Binary host forwarding protocol over one duplex Unix socket per request."""

import os
import struct

SOCKET = "/run/jailbox-forward.sock"
PROJECT = b"/home/jailbox/project"
CHUNK = 65536
# Requests begin with D (directory) and A (argv). C grants the client
# permission to send one I (input) chunk. Empty I means stdin EOF. O and E
# carry raw output. Only X reports a command exit; F reports service refusal.
# P is a readiness challenge or reply and can never start a request.
HEADER = struct.Struct("!cI")


def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        part = sock.recv(count - len(data))
        if not part:
            raise EOFError
        data.extend(part)
    return bytes(data)


def receive(sock, limit=CHUNK):
    kind, size = HEADER.unpack(recv_exact(sock, HEADER.size))
    if size > limit:
        raise ValueError("oversized forwarding message")
    return kind, recv_exact(sock, size)


def send(sock, kind, data=b""):
    sock.sendall(HEADER.pack(kind, len(data)) + data)


def write_all(fd, data):
    remaining = memoryview(data)
    while remaining:
        remaining = remaining[os.write(fd, remaining):]
