#!/usr/bin/env python3
"""Exercise bounded parallelism, failure aggregation, and interruption cleanup."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
runner = ["bash", str(root / "tests/fixtures/process-pool.sh")]
worker = str(root / "tests/fixtures/process-pool.py")


def records(directory, cases):
    fields = []
    for name, status in cases:
        args = [sys.executable, worker, directory, name, str(status)]
        fields.extend([name, str(len(args)), *args])
    return b"\0".join(os.fsencode(v) for v in fields) + b"\0"


with tempfile.TemporaryDirectory() as directory:
    result = subprocess.run(runner, input=records(directory, [(str(i), 7 if i == 2 else 0) for i in range(5)]),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    assert result.returncode == 1, result.stdout
    events = []
    for i in range(5):
        begin, end = json.loads((Path(directory) / f"{i}.json").read_text())
        events.extend([(begin, 1), (end, -1)])
        assert f"diagnostic {i}".encode() in result.stdout, result.stdout
        assert f"pool: {i}:".encode() in result.stdout, result.stdout
    count = peak = 0
    for _, delta in sorted(events):
        count += delta
        peak = max(peak, count)
    assert peak == 2, peak
    assert b"status 7" in result.stdout, result.stdout
    success = subprocess.run(runner, input=records(directory, [("success", 0)]),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    assert success.returncode == 0, success.stdout

with tempfile.TemporaryDirectory() as directory:
    process = subprocess.Popen(runner, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    child = None
    try:
        process.stdin.write(records(directory, [("slow", 0)]))
        process.stdin.close()
        process.stdin = None
        marker = Path(directory) / "slow.pid"
        deadline = time.monotonic() + 5
        while not marker.exists() or not marker.read_text():
            assert process.poll() is None, "runner exited before starting child"
            assert time.monotonic() < deadline, "child did not start"
            time.sleep(0.01)
        child = int(marker.read_text())
        process.send_signal(signal.SIGTERM)
        output, _ = process.communicate(timeout=10)
        assert process.returncode == 128 + signal.SIGTERM, output
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            child = None
        assert child is None, "pool child survived interrupted runner"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child is not None:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass

print("PASS: process pool overlaps jobs, stays bounded, retains failures, and reaps interrupted children")
