#!/usr/bin/env python3
"""Harmless host program used by forwarding tests."""

import os
import subprocess
import sys
import time
from pathlib import Path

mode = sys.argv[1]
if mode == "stream":
    data = sys.stdin.buffer.read()
    sys.stdout.buffer.write(data)
    sys.stderr.buffer.write(b"error\0\xff\n")
    sys.exit(42)
elif mode == "first-line":
    # Like `head -1`, stop reading while input is still arriving, then keep
    # writing output after stdin is closed.
    sys.stdout.buffer.write(sys.stdin.buffer.readline())
    sys.stdout.flush()
    os.close(0)
    time.sleep(0.2)
    print("still running", flush=True)
elif mode == "args":
    sys.stdout.buffer.write(b"\0".join(map(os.fsencode, sys.argv[2:])) + b"\0")
elif mode == "directory":
    print(os.getcwd())
    print(os.environ["FORWARDING_TEST_HOST"])
    print(Path(sys.argv[2]).read_text(), end="")
elif mode == "hold":
    child = subprocess.Popen((sys.executable, "-c", "import time; time.sleep(60)"))
    print(child.pid, flush=True)
    time.sleep(60)
elif mode == "effect":
    Path("forwarded-effect").write_text("host command ran")
elif mode == "terminal":
    print(*(os.isatty(fd) for fd in range(3)))
