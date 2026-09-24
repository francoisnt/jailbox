#!/usr/bin/env python3
"""Fingerprint the default repository lint inputs; uncertainty disables reuse."""
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import sys


def unreadable(error):
    raise error


def fingerprint():
    # Custom options/configuration can change source search paths and coverage.
    if os.environ.get("SHELLCHECK_OPTS") or os.environ.get("SHELLCHECK_LIB"):
        return None
    root = Path.cwd().resolve()
    directories = (root, *root.parents, Path.home(),
                   Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))))
    if any((directory / name).exists() for directory in directories
           for name in (".shellcheckrc", "shellcheckrc")):
        return None
    files = []
    for name in ("src", "scripts", "tests"):
        for directory, children, names in os.walk(name, onerror=unreadable):
            children.sort()
            if any((Path(directory) / child).is_symlink() for child in children):
                return None
            for filename in names:
                if filename in (".shellcheckrc", "shellcheckrc"):
                    return None
                if filename == ".env" or filename.endswith(".env"):
                    return None
                files.append(Path(directory) / filename)
    # This declared, repository-owned source is also followed by ShellCheck.
    files.append(Path("versions.env"))
    digest = hashlib.sha256()
    for value in ("lint-cache-v1", sys.platform, platform.machine()):
        digest.update(value.encode() + b"\0")
    binary = shutil.which("shellcheck")
    if binary is None:
        return None
    digest.update(Path(binary).read_bytes())
    for path in sorted(files):
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            return None
        digest.update(os.fsencode(path) + b"\0")
        if not path.exists():
            digest.update(b"missing\0")
            continue
        data = path.read_bytes()
        # Our source directives name files within these fingerprinted trees.
        # New external dependencies/search paths require an uncached check.
        shell = path.suffix == ".sh" or data.startswith((b"#!/bin/bash", b"#!/bin/sh", b"#!/usr/bin/env bash", b"#!/usr/bin/env sh"))
        if shell and b"source-path=" in data:
            return None
        if shell and re.search(rb"(?:\bsource|(?:^|[;\s])\.)\s+['\"]?(?:/|\.\./)", data):
            return None
        for dependency in re.findall(rb"shellcheck\s+source=([^\s]+)", data) if shell else ():
            if dependency == b"/dev/null":
                continue
            source = Path(os.fsdecode(dependency))
            if (not source.parts or source.is_absolute() or ".." in source.parts or
                    not (source == Path("versions.env") or source.parts[0] in ("src", "scripts", "tests"))):
                return None
        digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()


if __name__ == "__main__":
    try:
        key = fingerprint()
    except OSError:
        key = None
    if key:
        print(key)
