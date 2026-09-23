#!/usr/bin/env python3
"""Supervise one portable suite and clean up its process group on cancellation."""
import os
import signal
import subprocess
import sys


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    child = subprocess.Popen(sys.argv[1:], start_new_session=True)
    try:
        status = child.wait()
        return status if status >= 0 else 128 - status
    finally:
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


if __name__ == "__main__":
    sys.exit(main())
