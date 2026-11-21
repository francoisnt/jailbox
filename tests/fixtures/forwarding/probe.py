"""Convergence SSH double. Connect to the actual named host Unix socket."""

import os
import socket
import sys
from pathlib import Path

root, state, challenge = sys.argv[1:]
sys.path.insert(0, str(Path(root) / "src/container/runtime/lib/jailbox"))
from forward_protocol import receive, send

os.chdir(state)
with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(2)
    sock.connect("requests.sock")
    send(sock, b"P", challenge.encode("ascii"))
    kind, value = receive(sock, 64)
    if kind != b"P":
        raise SystemExit(1)
    print(value.decode("ascii"))
