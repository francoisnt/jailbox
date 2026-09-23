#!/usr/bin/env python3
"""Controlled suites for the portable scheduler's isolation and cancellation tests."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(os.environ["PORTABLE_FIXTURE"])
name = Path(sys.argv[1]).stem
mode = os.environ.get("PORTABLE_FIXTURE_MODE", "pass")


def interrupted(_signal, _frame):
    raise SystemExit(143)


signal.signal(signal.SIGTERM, interrupted)
(root / f"{name}.start").write_text(json.dumps([time.monotonic(), os.getpid()]))
child = None
try:
    if mode == "cancel":
        child = subprocess.Popen(["sleep", "30"])
        (root / f"{name}.child").write_text(str(child.pid))
        child.wait()
    else:
        time.sleep(0.15)
        print(f"diagnostic for {name}")
        if mode == "fail" and name == "a":
            sys.exit(7)
finally:
    if child is not None:
        child.terminate()
        child.wait(timeout=3)
    (root / f"{name}.end").write_text(str(time.monotonic()))
