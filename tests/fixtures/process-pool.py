#!/usr/bin/env python3
"""Short child processes for shared pool concurrency and cleanup tests."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
name, status = sys.argv[2:]
started = time.monotonic()
(root / f"{name}.pid").write_text(str(os.getpid()))
if name in ("0", "1"):
    other = root / f"{1 - int(name)}.pid"
    deadline = started + 5
    while not other.exists():
        if time.monotonic() > deadline:
            sys.exit(99)
        time.sleep(0.01)
time.sleep(30 if name == "slow" else 0.1)
(root / f"{name}.json").write_text(json.dumps([started, time.monotonic()]))
print(f"diagnostic {name}")
sys.exit(int(status))
