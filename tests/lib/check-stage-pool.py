"""Exercise bounded stage lifetime, assertion/crash results and cancellation."""
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import time

runner = sys.argv[1]


def until(predicate):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("timed out")
        time.sleep(0.02)


def run_case(workers, cancel=False, ledger=False):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        stages = ["one", "two", "crash", "assertion"]
        env = dict(os.environ, JAILBOX_TEST_PROGRESS_TERMINAL="true", STAGE_TEST_WORKERS=str(workers), STAGE_TEST_LEDGER=str(int(ledger)))
        with (root / "output").open("w") as output:
            process = subprocess.Popen(
                ["bash", runner, directory, "fixture_stage", *stages],
                env=env, stdout=output, stderr=subprocess.STDOUT,
            )
            try:
                until(lambda: (root / "one.started").exists())
                if workers == 2:
                    until(lambda: (root / "two.started").exists())
                else:
                    assert not (root / "two.started").exists()
                assert not (root / "crash.started").exists()
                if cancel:
                    process.terminate()
                    assert process.wait(timeout=10) != 0
                    assert (root / "one.cleaned").exists()
                    assert (root / "two.cleaned").exists()
                    assert not (root / "crash.started").exists()
                else:
                    for stage in stages:
                        (root / f"{stage}.release").touch()
                    assert process.wait(timeout=10) != 0
                    assert not (root / "should-not-exist").exists()
                    for stage in stages:
                        assert (root / f"{stage}.cleaned").exists()
                        expected = "0" if stage in ("one", "two") else "1"
                        assert (root / f"{stage}.exit-status").read_text().strip() == expected
                for stage in ("one", "two") if cancel else stages:
                    lines = (root / f"{stage}.log").read_text().splitlines()
                    assert lines[-1].endswith("fixture cleanup finished"), lines
                    assert all(re.match(r"^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] ", line) for line in lines)
                    assert (root / f"{stage}.phases").read_text().startswith("fixture|")
                assert (root / "parent.cleaned").exists()
                assert (root / "worker-context").stat().st_mode & 0o777 == 0o600
            finally:
                for stage in stages:
                    (root / f"{stage}.release").touch()
                if process.poll() is None:
                    process.wait(timeout=10)


run_case(1)
run_case(2)
run_case(2, cancel=True)
run_case(2, ledger=True)
run_case(2, cancel=True, ledger=True)
print("PASS: bounded stages, cleanup, crashes, assertions, and cancellation")
