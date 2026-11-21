"""Convergence SSH double. Connect to the real host service's Unix socket."""

import os
import socket
import struct
import sys

state, challenge = sys.argv[1:]
os.chdir(state)
with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(2)
    sock.connect("requests.sock")
    sock.sendall(struct.pack("!cI", b"P", len(challenge)) + challenge.encode("ascii"))
    with sock.makefile("rb") as stream:
        kind, size = struct.unpack("!cI", stream.read(5))
        if kind != b"P" or size != 64:
            raise SystemExit(1)
        response = stream.read(size)
        if len(response) != size:
            raise SystemExit(1)
        print(response.decode("ascii"))
