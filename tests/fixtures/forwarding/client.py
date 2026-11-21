"""Run the installed-style forwarding client against the fixture's socket."""

import os
import socket
import sys
from pathlib import Path

lib = Path(__file__).resolve().parents[3] / "src/container/runtime/lib/jailbox"
sys.path.insert(0, str(lib))
import forward_client

assert sys.argv[1] == "--" and len(sys.argv) == 3
forward_client.PROJECT = os.getcwdb()
with socket.socket(socket.AF_UNIX) as sock:
    os.chdir(os.environ["FORWARDING_TEST_STATE"])
    sock.connect("requests.sock")
    os.chdir(forward_client.PROJECT)
    sys.exit(forward_client.forward(sock, os.fsencode(sys.argv[2])))
