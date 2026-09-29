#!/usr/bin/env python3
"""Controlled suites for the portable scheduler's isolation and cancellation tests."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

assert os.environ.get("JAILBOX_TEST_PROGRESS_TERMINAL") == "false", "captured suite inherited terminal cadence"
root = Path(os.environ["PORTABLE_FIXTURE"])
name = Path(sys.argv[1]).stem
mode = os.environ.get("PORTABLE_FIXTURE_MODE", "pass")


def interrupted(_signal, _frame):
    raise SystemExit(143)


signal.signal(signal.SIGTERM, interrupted)
(root / f"{name}.start").write_text(json.dumps([time.monotonic(), os.getpid()]))
child = None
try:
    if (mode == "cancel" or (mode == "parallel-cancel" and name == "d")
            or (mode == "harness-cancel" and name == "c-exclusive")):
        child = subprocess.Popen(["sleep", "30"])
        (root / f"{name}.child").write_text(str(child.pid))
        child.wait()
    elif mode == "pass":
        # The checker releases workers only after observing the expected batch.
        marker = root / f"{name}.release"
        deadline = time.monotonic() + 10
        while not marker.exists():
            assert time.monotonic() < deadline, f"missing barrier: {marker.name}"
            time.sleep(0.02)
        print(f"diagnostic for {name}")
    elif mode == "fail" and name in ("a", "b"):
        # Start both workers before failing. Keep b active until the checker
        # observes the coordinator reporting a's failure, then permit cleanup.
        marker = root / ("b.start" if name == "a" else "release-b")
        deadline = time.monotonic() + 10
        while not marker.exists():
            assert time.monotonic() < deadline, f"missing barrier: {marker.name}"
            time.sleep(0.02)
        print(f"diagnostic for {name}")
        if name == "a":
            sys.exit(7)
    else:
        time.sleep(0.15)
        print(f"diagnostic for {name}")
        if mode == "parallel-fail" and name == "d":
            sys.exit(7)
        if mode == "harness-fail" and name == "c-exclusive":
            sys.exit(7)
finally:
    if child is not None:
        child.terminate()
        child.wait(timeout=3)
    print(f"cleanup for {name}", flush=True)
    (root / f"{name}.end").write_text(str(time.monotonic()))
