#!/usr/bin/env python3
"""Check failure and cancellation through the real matrix coordinator."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

tree = Path(sys.argv[1])
script = tree / "tests/integration/lifecycle-state.sh"
env = dict(os.environ, PATH=f"{tree / 'bin'}:{os.environ['PATH']}",
           JAILBOX_TEST_LEDGER_DIR=str(tree / "ledger"), JAILBOX_LIFECYCLE_JOBS="2",
           JAILBOX_TEST_LOG_SCRIPT=str(script), JAILBOX_LIFECYCLE_TIMINGS="/dev/null")
failed = subprocess.run(["bash", str(script)], env=dict(env, POOL_TEST_MODE="fail"),
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
assert failed.returncode != 0, failed.stdout
assert b"worker failure or incomplete coverage" in failed.stdout, failed.stdout
assert b"exit 42" in failed.stdout, failed.stdout
assert not list((tree / "ledger").glob("*.ledger"))

with (tree / "cancel-output").open("wb") as output:
    coordinator = subprocess.Popen(["bash", str(script)], env=dict(env, POOL_TEST_MODE="wait"),
                                   stdout=output, stderr=subprocess.STDOUT)
    workers = []
    try:
        deadline = time.monotonic() + 15
        while True:
            markers = list((tree / "testlog").glob("lifecycle-*/mock-started-*"))
            if len(markers) == 2 and all(p.read_text().strip() for p in markers):
                workers = [int(p.read_text()) for p in markers]
                break
            assert coordinator.poll() is None, "coordinator exited before workers started"
            assert time.monotonic() < deadline, "workers did not start"
            time.sleep(0.02)
        run = markers[0].parent
        coordinator.send_signal(signal.SIGTERM)
        assert coordinator.wait(timeout=15) != 0
        for pid in workers:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            raise AssertionError(f"worker {pid} survived cancellation")
        workers = []
        assert len(list(run.glob("worker-*/stopped"))) == 2
        assert not list((tree / "ledger").glob("*.ledger"))
        for fixture in run.glob("worker-*/fixture"):
            assert not Path(fixture.read_text().strip()).exists()
    finally:
        if coordinator.poll() is None:
            coordinator.kill()
            coordinator.wait()
        for pid in workers:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

print("PASS: matrix worker failures propagate; cancellation joins workers before ledger cleanup")
