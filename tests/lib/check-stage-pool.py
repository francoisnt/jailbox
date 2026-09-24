"""Exercise bounded stage lifetime, assertion/crash results and cancellation."""
import os
import re
import signal
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


def run_case(workers, cancel=None, ledger=False):
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
                    process.send_signal(cancel)
                    assert process.wait(timeout=10) == 128 + cancel
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
                assert not (root / "dependency-lost").exists()
                if not cancel:
                    assert (root / "totals").read_text().strip() == "3 2"
                    assert (root / "failed-stages").read_text().splitlines() == ["crash", "assertion"]
                    output.flush()
                    transcript = (root / "output").read_text()
                    assert "fixture/explicit/one" in transcript
                    assert "fixture/explicit/one/fixture" in transcript
                assert (root / "parent.cleaned").read_text().strip() == str(process.returncode)
                assert (root / "worker-context").stat().st_mode & 0o777 == 0o600
            finally:
                for stage in stages:
                    (root / f"{stage}.release").touch()
                if process.poll() is None:
                    process.wait(timeout=10)


run_case(1)
run_case(2)
run_case(2, ledger=True)
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    run_case(2, cancel=sig)
    run_case(2, cancel=sig, ledger=True)

# Result accounting, including workers that never launch, runs under the same
# conditional invocation used by the real coordinators.
for launch_failure in (False, True):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        stages = ["one", "bad-counts", "missing-counts", "failed-exit", "cleanup-failure"]
        for stage in stages:
            (root / f"{stage}.release").touch()
        result = subprocess.run(
            ["bash", runner, directory, "fixture_stage", *stages],
            env=dict(os.environ, STAGE_TEST_WORKERS="2", STAGE_TEST_LAUNCH_FAILURE=str(int(launch_failure))),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10,
        )
        assert result.returncode != 0, result.stdout
        assert (root / "totals").read_text().strip() == ("0 5" if launch_failure else "4 4")
        assert (root / "failed-stages").read_text().splitlines() == (stages if launch_failure else stages[1:])
        if not launch_failure:
            assert (root / "failed-exit.exit-status").read_text().strip() == "42"
            assert (root / "cleanup-failure.exit-status").read_text().strip() == "23"
        assert not (root / "dependency-lost").exists()

# A report write failure must fail the pool without pretending an assertion
# failed; successful CI runs still publish grouped, timestamped stage logs.
for report_failure in (False, True):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "one.release").touch()
        if report_failure:
            (root / "one.exit-status").mkdir()
        result = subprocess.run(
            ["bash", runner, directory, "fixture_stage", "one"],
            env=dict(os.environ, STAGE_TEST_WORKERS="1", GITHUB_ACTIONS="true"),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10,
        )
        assert (result.returncode != 0) == report_failure, result.stdout
        assert (root / "totals").read_text().strip() == "1 0"
        assert (root / "failed-stages").read_text().strip() == ("one" if report_failure else "")
        if not report_failure:
            assert b"::group::fixture/explicit/one" in result.stdout
            assert b"::endgroup::" in result.stdout

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        result = subprocess.run(
            ["bash", runner, directory, "fixture_stage", "one"],
            env=dict(os.environ, STAGE_TEST_WORKERS="1", STAGE_TEST_LEDGER="1",
                     STAGE_TEST_REGISTRATION_SIGNAL=str(int(sig))),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10,
        )
        assert result.returncode == 128 + sig, result.stdout
        assert (root / "one.cleaned").exists()
        assert not (root / "dependency-lost").exists()
        assert (root / "parent.cleaned").read_text().strip() == str(result.returncode)
print("PASS: bounded stages, cleanup, crashes, assertions, and cancellation")
