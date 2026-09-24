#!/usr/bin/env python3
"""Supervise one portable suite and clean up its process group on cancellation."""
import os
import signal
import subprocess
import sys
import re
import selectors
import time
from datetime import datetime, timezone
from pathlib import Path


interruption = 0
log_root = os.fsencode(os.environ.get("JAILBOX_TEST_LOG_ROOT", str(Path(__file__).resolve().parents[2])))
root_reference = re.compile(re.escape(log_root) + rb"(?=$|[ \"':)\t])")
trace_directory = os.environ.get("JAILBOX_TEST_SUPERVISOR_TRACE")


def trace(event, **fields):
    # Opt-in diagnostics use a separate file so a broken output pipe cannot
    # hide supervisor state. Diagnostic failures must not change supervision.
    if trace_directory:
        try:
            with open(Path(trace_directory) / f"supervisor-{os.getpid()}.trace", "a") as stream:
                stream.write(f"{time.monotonic():.6f} {event} {fields!r}\n")
        except OSError:
            pass


def interrupted(signum, _frame):
    global interruption
    interruption = interruption or signum


def write_line(line):
    line = line.replace(log_root + b"/", b"")
    line = root_reference.sub(b".", line)
    if not re.match(rb"^\s*\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\]", line):
        line = datetime.now(timezone.utc).strftime("[%Y-%m-%dT%H:%M:%SZ] ").encode() + line
    sys.stdout.buffer.write(line + b"\n")
    sys.stdout.buffer.flush()


def main():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    # The coordinator may own a terminal, but this child's output is captured.
    # Nested tools must use log cadence rather than terminal redraw cadence.
    environment = dict(os.environ, JAILBOX_TEST_PROGRESS_TERMINAL="false",
                       JAILBOX_TEST_LOG_ROOT=os.fsdecode(log_root))
    child = subprocess.Popen(sys.argv[1:], start_new_session=True, env=environment,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    trace("started", pid=os.getpid(), ppid=os.getppid(), pgid=os.getpgrp(), child=child.pid)
    try:
        pending = b""
        ended = None
        output_open = True
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                events = selector.select(.1)
                if not output_open and child.poll() is not None:
                    break
                if interruption or child.poll() is not None:
                    # Match the original supervisor's cleanup contract even if
                    # descendants retain the log pipe after the suite exits.
                    if ended is None:
                        ended = time.monotonic()
                        trace("terminate-group", signal=interruption, child_status=child.returncode)
                        try:
                            os.killpg(child.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    if time.monotonic() - ended >= 5:
                        trace("kill-deadline", child_status=child.returncode, output_open=output_open)
                        try:
                            os.killpg(child.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        break
                if not events:
                    continue
                chunk = os.read(child.stdout.fileno(), 65536)
                trace("read", bytes=len(chunk), child_status=child.returncode)
                if not chunk:
                    selector.unregister(child.stdout)
                    output_open = False
                    continue
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    write_line(line)
                    trace("line-written", bytes=len(line))
        if pending:
            write_line(pending)
        status = child.wait()
        trace("finished", child_status=status, signal=interruption, pending_bytes=len(pending))
        return 128 + interruption if interruption else (status if status >= 0 else 128 - status)
    finally:
        trace("finally", child_status=child.returncode, signal=interruption)
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # Also covers descendants surviving a failed or interrupted suite.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        trace("joined", child_status=child.returncode)


if __name__ == "__main__":
    sys.exit(main())
