#!/usr/bin/env python3
"""Lint current contents of changed shell files; full context coverage stays in CI."""

import os
from pathlib import Path
import subprocess
import sys


def changed_paths():
    paths = set()
    # Separate index/worktree queries also include staged changes subsequently
    # undone in the worktree. Always lint the file that exists now, not its blob.
    for args in (
        ["diff", "--name-only", "-z", "--no-renames"],
        ["diff", "--cached", "--name-only", "-z", "--no-renames"],
        ["ls-files", "--others", "--exclude-standard", "-z"],
    ):
        paths.update(os.fsdecode(p) for p in subprocess.check_output(["git", *args]).split(b"\0") if p)
    return sorted(paths)


def options(name):
    path = Path(name)
    if path.suffix == ".env":
        return None
    host = name == "src/public-api.sh" or (name.startswith("src/host/") and name.endswith(".sh"))
    bash = (host or name in ("src/jailbox", "src/install.sh", "tests/run")
            or (name.startswith(("scripts/", "tests/")) and name.endswith(".sh")))
    container = name.startswith("src/container/")
    if not (bash or container) or not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"cannot lint changed shell candidate: {name}")
    if container:
        with path.open("rb") as stream:
            interpreter = stream.readline().rstrip(b"\n")
        if interpreter in (b"#!/bin/sh", b"#!/usr/bin/env sh"):
            return ("--shell=sh",)
        if interpreter in (b"#!/bin/bash", b"#!/usr/bin/env bash"):
            return ("--shell=bash",)
        if path.suffix == ".sh" or name.startswith("src/container/runtime/bin/"):
            raise ValueError(f"unsupported shell shebang in {name}")
        return None
    if name == "src/jailbox":
        return ("--check-sourced", "--external-sources", "--shell=bash")
    if host:
        return ("--external-sources", "--shell=bash", "--exclude=SC2034,SC2329")
    return ("--external-sources", "--shell=bash")


def main():
    groups = {}
    for name in changed_paths():
        flags = options(name)
        if flags is not None:
            groups.setdefault(flags, []).append(name)
    count = sum(map(len, groups.values()))
    if not count:
        print("Worktree ShellCheck: no changed shell files (partial coverage).")
        return 0
    for flags, names in groups.items():
        for start in range(0, len(names), 8):
            batch = names[start:start + 8]
            print("Worktree ShellCheck: " + ", ".join(batch), flush=True)
            result = subprocess.run(["shellcheck", *flags, *sys.argv[1:], "--", *batch])
            if result.returncode:
                return result.returncode
    print(f"Worktree ShellCheck passed: {count} changed shell file(s); partial coverage.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Worktree ShellCheck failed: {error}", file=sys.stderr)
        sys.exit(1)
