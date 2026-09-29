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
    for sub in ("tests/unit", "tests/harness/parallel", "tests/harness/exclusive", "tests/lib", "run"):
        (tree / sub).mkdir(parents=True)
    shutil.copy(root / "tests/lib/run-suite.py", tree / "tests/lib/run-suite.py")
    for name in ("a", "b", "c-exclusive", "d", "z-new"):
        group = ("harness/exclusive" if name in ("c-exclusive", "z-new")
                 else "harness/parallel" if name == "d" else "unit")
        (tree / f"tests/{group}/{name}.sh").write_text(
            '#!/bin/bash\nexec python3 "$PORTABLE_FIXTURE_WORKER" "$0"\n')
    return dict(os.environ, JAILBOX_TEST_PROGRESS_TERMINAL="true", PORTABLE_FIXTURE=directory,
                PORTABLE_FIXTURE_WORKER=str(root / "tests/fixtures/portable-pool/suite.py"))


def cancellation_diagnostics(tree, process, events):
    # Print before TemporaryDirectory removes the evidence. The outer portable
    # suite capture retains this in both CI output and the uploaded suite log.
    print(f"Cancellation diagnostics: coordinator={process.pid} status={process.poll()} "
          f"platform={sys.platform} python={sys.version.split()[0]}", file=sys.stderr)
    for event in events:
        print(event, file=sys.stderr)
    for pattern in ("output", "*.start", "*.child", "*.end", "*.trace", "run/*", "run/**/*.log"):
        for path in sorted(tree.glob(pattern)):
            if not path.is_file():
                continue
            try:
                data = path.read_bytes()
                print(f"--- {path.relative_to(tree)} ({len(data)} bytes) ---\n"
                      + data.decode(errors="replace"), file=sys.stderr)
            except OSError as error:
                print(f"Cannot read {path.relative_to(tree)}: {error.strerror}", file=sys.stderr)
    # No command arguments or environment: just process identities and state.
    try:
        snapshot = subprocess.run(["ps", "-ax", "-o", "pid,ppid,pgid,stat,etime,comm"],
                                  capture_output=True, text=True, timeout=3)
        print(f"--- process snapshot (status {snapshot.returncode}) ---\n"
              + snapshot.stdout + snapshot.stderr, file=sys.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Process snapshot unavailable: {type(error).__name__}", file=sys.stderr)


for workers in (1, 3):
    with tempfile.TemporaryDirectory() as directory:
        env = prepare(directory)
        tree = Path(directory)
        # Hold each expected batch until every member has started. Startup
        # latency cannot erase the overlap, and an unintended serial barrier
        # cannot pass merely because the machine happened to be fast.
        batches = ([("a",), ("b",), ("d",)] if workers == 1 else [("a", "b", "d")])
        batches += [("c-exclusive",), ("z-new",)]
        with (tree / "output").open("wb") as output:
            process = subprocess.Popen(["bash", str(runner), str(root), directory, str(workers)],
                                       env=env, stdout=output, stderr=subprocess.STDOUT)
            try:
                for batch in batches:
                    deadline = time.monotonic() + 10
                    while not all((tree / f"{name}.start").exists() for name in batch):
                        assert process.poll() is None, (tree / "output").read_text()
                        assert time.monotonic() < deadline, f"batch did not start: {batch}"
                        time.sleep(0.02)
                    assert all(not (tree / f"{name}.end").exists() for name in batch)
                    for name in batch:
                        (tree / f"{name}.release").touch()
                assert process.wait(timeout=10) == 0, (tree / "output").read_text()
            finally:
                for batch in batches:
                    for name in batch:
                        (tree / f"{name}.release").touch()
                if process.poll() is None:
                    process.wait(timeout=15)
        assert (tree / "run/summary").read_text().strip() == "5|0"
        intervals = {}
        for start in tree.glob("*.start"):
            intervals[start.stem] = (json.loads(start.read_text())[0], float(start.with_suffix(".end").read_text()))
        for exclusive in ("c-exclusive", "z-new"):
            a, b = intervals[exclusive]
            assert all(name == exclusive or end <= a or begin >= b for name, (begin, end) in intervals.items())
            assert all(intervals[name][1] <= a for name in ("a", "b", "d"))
        a, b = intervals["a"], intervals["b"]
        assert (max(a[0], b[0]) < min(a[1], b[1])) == (workers > 1)
        if workers > 1:
            # The harness worker shares the pool with product workers.
            d = intervals["d"]
            assert any(max(d[0], intervals[name][0]) < min(d[1], intervals[name][1])
                       for name in ("a", "b"))
        events = sorted((timestamp, delta) for begin, end in intervals.values()
                        for timestamp, delta in ((begin, 1), (end, -1)))
        active = 0
        for _, delta in events:
            active += delta
            assert 0 <= active <= workers
        assert len(intervals) == 5
        assert len(list((tree / "run").glob("**/*.log"))) == 5
        for log in (tree / "run").glob("**/*.log"):
            lines = log.read_text().splitlines()
            assert lines and all(re.match(r"^\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] ", line) for line in lines)
            assert lines[-1].endswith("cleanup for " + log.name.removesuffix(".sh.log"))

# Two active workers and a queued parallel suite: observe failure while the
# other worker remains alive, then let it finish. No scheduling race determines
# how many suites started or whether the coordinator joined the survivor.
with tempfile.TemporaryDirectory() as directory:
    env = dict(prepare(directory), PORTABLE_FIXTURE_MODE="fail")
    tree = Path(directory)
    with (tree / "output").open("wb") as output:
        process = subprocess.Popen(["bash", str(runner), str(root), directory, "2"],
                                   env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while "Rerun: tests/run dev a" not in (tree / "output").read_text():
                assert process.poll() is None, (tree / "output").read_text()
                assert time.monotonic() < deadline, "failure was not reported"
                time.sleep(0.02)
            assert (tree / "b.start").exists()
            assert not (tree / "b.end").exists()
            assert process.poll() is None, "coordinator abandoned the active suite"
            assert not (tree / "d.start").exists()
            (tree / "release-b").touch()
            assert process.wait(timeout=10) != 0
            assert {p.stem for p in tree.glob("*.start")} == {"a", "b"}
            assert {p.stem for p in tree.glob("*.end")} == {"a", "b"}
            assert (tree / "run/summary").read_text().strip() == "1|1"
            assert "diagnostic for a" in (tree / "output").read_text()
        finally:
            (tree / "release-b").touch()
            if process.poll() is None:
                process.wait(timeout=15)

with tempfile.TemporaryDirectory() as directory:
    env = dict(prepare(directory), PORTABLE_FIXTURE_MODE="parallel-fail")
    result = subprocess.run(["bash", str(runner), str(root), directory, "3"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    assert result.returncode != 0, result.stdout
    assert (Path(directory) / "run/summary").read_text().strip() == "2|1"
    assert not (Path(directory) / "c-exclusive.start").exists()
    assert b"diagnostic for d" in result.stdout
    assert b"Rerun: tests/run dev d" in result.stdout

with tempfile.TemporaryDirectory() as directory:
    env = dict(prepare(directory), PORTABLE_FIXTURE_MODE="harness-fail")
    result = subprocess.run(["bash", str(runner), str(root), directory, "3"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
    assert result.returncode != 0, result.stdout
    assert (Path(directory) / "run/summary").read_text().strip() == "3|1"
    assert not (Path(directory) / "z-new.start").exists()
    assert b"diagnostic for c-exclusive" in result.stdout
    assert b"Rerun: tests/run dev c-exclusive" in result.stdout

# Ambiguous dev names and missing discovery directories must fail before work.
for invalid in ("duplicate", "missing-directory", "unclassified"):
    with tempfile.TemporaryDirectory() as directory:
        env = prepare(directory)
        tree = Path(directory)
        if invalid == "duplicate":
            shutil.copy(tree / "tests/unit/a.sh", tree / "tests/harness/parallel/a.sh")
        elif invalid == "unclassified":
            shutil.copy(tree / "tests/unit/a.sh", tree / "tests/harness/stray.sh")
        else:
            shutil.rmtree(tree / "tests/harness/exclusive")
        result = subprocess.run(["bash", str(runner), str(root), directory, "3"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        assert result.returncode != 0, result.stdout
        assert not list(tree.glob("*.start"))
        if invalid == "duplicate":
            assert b"Duplicate portable suite name: a.sh" in result.stdout

for mode, group, names in (("cancel", "unit", ("a", "b")),
                           ("parallel-cancel", "harness/parallel", ("d",)),
                           ("harness-cancel", "harness/exclusive", ("c-exclusive",))):
    with tempfile.TemporaryDirectory() as directory:
        env = dict(prepare(directory), PORTABLE_FIXTURE_MODE=mode,
                   JAILBOX_TEST_SUPERVISOR_TRACE=directory)
        events = []
        with (Path(directory) / "output").open("wb") as log:
            process = subprocess.Popen(["bash", str(runner), str(root), directory, "2"], env=env,
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            events.append(f"{time.monotonic():.6f} coordinator started pid={process.pid}")
            try:
                deadline = time.monotonic() + 10
                while len(list(Path(directory).glob("*.child"))) != len(names):
                    assert time.monotonic() < deadline, "suite children did not start"
                    time.sleep(.02)
                events.append(f"{time.monotonic():.6f} sending SIGTERM to group {process.pid}")
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
                events.append(f"{time.monotonic():.6f} coordinator reaped status={process.returncode}")
                deadline = time.monotonic() + 10
                # Worker cleanup markers precede the supervisor's final log
                # flush. Both must arrive before inspecting captured output.
                while not all(
                    (Path(directory) / f"{name}.end").exists()
                    and "cleanup for " + name in
                    (Path(directory) / f"run/{group}/{name}.sh.log").read_text()
                    for name in names
                ):
                    assert time.monotonic() < deadline, "suite cleanup or log capture did not finish"
                    time.sleep(.02)
                events.append(f"{time.monotonic():.6f} cleanup markers observed")
                assert not (Path(directory) / "z-new.start").exists()
                for name in names:
                    transcript = (Path(directory) / f"run/{group}/{name}.sh.log").read_text()
                    assert "cleanup for " + name in transcript, f"missing cleanup output: {name}: {transcript!r}"
                for marker in Path(directory).glob("*.child"):
                    try:
                        os.kill(int(marker.read_text()), 0)
                    except ProcessLookupError:
                        continue
                    raise AssertionError("suite descendant survived cancellation")
            except Exception:
                try:
                    cancellation_diagnostics(Path(directory), process, events)
                except Exception as error:
                    print(f"Diagnostic collection failed: {type(error).__name__}: {error}", file=sys.stderr)
                raise
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
