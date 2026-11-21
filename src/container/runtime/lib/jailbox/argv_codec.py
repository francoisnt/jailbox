"""Decode the argument frame used by SSH exec and host command forwarding."""

import base64
import os
import re
import signal
import sys
from pathlib import Path

limit, grammar = Path(__file__).with_name("argv-frame").read_bytes().splitlines()
ARGV_LIMIT = int(limit)
ARGV_GRAMMAR = re.compile(grammar)


def decode_argv(frame):
    if not frame or len(frame) > ARGV_LIMIT or not ARGV_GRAMMAR.fullmatch(frame):
        raise ValueError("invalid argument frame")
    args = base64.b64decode(frame, validate=True).split(b"\0")
    if not args[0] or args[-1] != b"":
        raise ValueError("invalid argument frame")
    return args[:-1]


def exec_argv(directory, frames):
    try:
        if len(frames) != 1:
            raise ValueError("expected one argument frame")
        argv = decode_argv(os.fsencode(frames[0]))
    except ValueError:
        print("Error: invalid jailbox exec frame", file=sys.stderr)
        return 2
    try:
        # Keep Bash's cd, executable lookup and text-file fallback.
        # Pass the directory and command as positional arguments to fixed code.
        command = b'cd "$1" || exit 1\nshift\nexec -- "$@"'
        # Like subprocess, restore signals Python ignores at startup.
        for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ"):
            sig = getattr(signal, name, None)
            if sig is not None:
                signal.signal(sig, signal.SIG_DFL)
        os.execv("/bin/bash", [b"/bin/bash", b"-pc", command, b"jailbox-exec-argv", os.fsencode(directory), *argv])
    except OSError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(exec_argv(sys.argv[1], sys.argv[2:]))
