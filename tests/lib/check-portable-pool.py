#!/usr/bin/env python3
"""Exercise real portable scheduling with deterministic isolated suites."""
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
runner = root / "tests/fixtures/portable-pool/runner.sh"


def prepare(directory):
    tree = Path(directory)
    for sub in ("tests/unit", "tests/lib", "run"):
        (tree / sub).mkdir(parents=True)
    shutil.copy(root / "tests/lib/run-suite.py", tree / "tests/lib/run-suite.py")
    (tree / "tests/lib/portable-parallel.txt").write_text("a.sh\nb.sh\nd.sh\n")
    for name in ("a", "b", "c-exclusive", "d", "z-new"):
        (tree / f"tests/unit/{name}.sh").write_text(
            '#!/bin/bash\nexec python3 "$PORTABLE_FIXTURE_WORKER" "$0"\n')
    return dict(os.environ, JAILBOX_TEST_PROGRESS_TERMINAL="true", PORTABLE_FIXTURE=directory,
                PORTABLE_FIXTURE_WORKER=str(root / "tests/fixtures/portable-pool/suite.py"))


for workers in (1, 3):
    with tempfile.TemporaryDirectory() as directory:
        env = prepare(directory)
        tree = Path(directory)
        result = subprocess.run(["bash", str(runner), str(root), directory, str(workers)],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        assert result.returncode == 0, result.stdout
        assert (tree / "run/summary").read_text().strip() == "5|0"
        intervals = {}
        for start in tree.glob("*.start"):
            intervals[start.stem] = (json.loads(start.read_text())[0], float(start.with_suffix(".end").read_text()))
        for exclusive in ("c-exclusive", "z-new"):
            a, b = intervals[exclusive]
            assert all(name == exclusive or end <= a or begin >= b for name, (begin, end) in intervals.items())
        a, b = intervals["a"], intervals["b"]
        assert (max(a[0], b[0]) < min(a[1], b[1])) == (workers > 1)
        assert len(list((tree / "run").glob("*.log"))) == 5
        for log in (tree / "run").glob("*.log"):
            lines = log.read_text().splitlines()
            assert lines and all(re.match(r"^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] ", line) for line in lines)
            assert lines[-1].endswith("cleanup for " + log.name.removesuffix(".sh.log"))

with tempfile.TemporaryDirectory() as directory:
    env = dict(prepare(directory), PORTABLE_FIXTURE_MODE="fail")
    result = subprocess.run(["bash", str(runner), str(root), directory, "3"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    assert result.returncode != 0, result.stdout
    assert (Path(directory) / "run/summary").read_text().strip() == "1|1"
    assert not (Path(directory) / "c-exclusive.start").exists()
    assert b"diagnostic for a" in result.stdout

with tempfile.TemporaryDirectory() as directory:
    env = dict(prepare(directory), PORTABLE_FIXTURE_MODE="cancel")
    with (Path(directory) / "output").open("wb") as log:
        process = subprocess.Popen(["bash", str(runner), str(root), directory, "2"], env=env,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while len(list(Path(directory).glob("*.child"))) != 2:
                assert time.monotonic() < deadline, "suite children did not start"
                time.sleep(.02)
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)
            deadline = time.monotonic() + 10
            while len(list(Path(directory).glob("*.end"))) != 2:
                assert time.monotonic() < deadline, "suite cleanup did not finish"
                time.sleep(.02)
            for name in ("a", "b"):
                transcript = (Path(directory) / f"run/{name}.sh.log").read_text()
                assert "cleanup for " + name in transcript, transcript
            for marker in Path(directory).glob("*.child"):
                try:
                    os.kill(int(marker.read_text()), 0)
                except ProcessLookupError:
                    continue
                raise AssertionError("suite descendant survived cancellation")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

with tempfile.TemporaryDirectory() as directory:
    marker = Path(directory) / "ready"
    code = "import os,signal,time; signal.signal(signal.SIGTERM, lambda *_: exit(0)); os.close(1); os.close(2); open(__import__('sys').argv[1], 'w').close(); time.sleep(30)"
    process = subprocess.Popen([sys.executable, str(root / "tests/lib/run-suite.py"),
                                sys.executable, "-c", code, str(marker)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while not marker.exists():
            assert time.monotonic() < deadline
            time.sleep(.02)
        process.terminate()
        process.communicate(timeout=7)
        assert process.returncode == 143
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()

print("PASS: portable discovery, bounded overlap, exclusive barriers, failure accounting, and descendant cleanup")
