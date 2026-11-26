#!/usr/bin/env python3
"""Harmless host program used by forwarding tests."""

import os
import signal
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
elif mode == "wait":
    time.sleep(60)
elif mode == "hold":
    child = subprocess.Popen((sys.executable, "-c", "import time; time.sleep(60)"))
    print(child.pid, flush=True)
    time.sleep(60)
elif mode == "effect":
    Path("forwarded-effect").write_text("host command ran")
elif mode == "terminal":
    print(*(os.isatty(fd) for fd in range(3)))
elif mode == "signals":
    input_finished = False
    exit_requested = False

    def received(signum, _frame):
        global exit_requested
        # The next signal can arrive as soon as its predecessor's output is
        # visible. Avoid re-entering Python's buffered stdout in the handler.
        os.write(1, (signal.Signals(signum).name + "\n").encode())
        if input_finished and signum == signal.SIGTERM:
            exit_requested = True

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, received)
    print("ready", flush=True)
    data = sys.stdin.buffer.read()
    input_finished = True
    sys.stdout.buffer.write(data)
    sys.stdout.flush()
    # Wait for the test's final signal instead of assuming it arrives within
    # a fixed time after stdin closes.
    while not exit_requested:
        time.sleep(0.01)
    sys.exit(37)
elif mode == "signal-exit":
    signum = getattr(signal, sys.argv[2])
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
elif mode == "status":
    sys.exit(int(sys.argv[2]))
elif mode == "blocked-input":
    released = False
    def release(_signum, _frame):
        global released
        released = True
        os.write(1, b"released\n")
    signal.signal(signal.SIGINT, release)
    print("ready", flush=True)
    while not released:
        time.sleep(0.01)
    sys.stdout.buffer.write(sys.stdin.buffer.read())
    sys.stdout.flush()
elif mode == "survivor":
    subprocess.Popen((sys.executable, __file__, "survivor-child", str(os.getpid())))
    sys.exit(23)
elif mode == "survivor-child":
    def stop(_signum, _frame):
        os.write(1, b"descendant received signal\n")
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    while os.getppid() == int(sys.argv[2]):
        time.sleep(0.01)
    print("descendant ready", flush=True)
    time.sleep(60)
