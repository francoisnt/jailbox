"""Command-line entry for core's private forwarding resource operations."""

import base64
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import service


def main(command, args):
    original_umask = os.umask(0o077)
    if command == "capture":
        print(base64.b64encode(service.capture(*args)).decode("ascii"))
    elif command == "describe":
        # The bounded snapshot is a private stream, never a process argument.
        print(json.dumps(service.prepare(args[0], sys.stdin.buffer.read(), original_umask)))
    elif command == "publish":
        project, state, server, digest, *hidden_paths = args
        encoded = sys.stdin.buffer.readline().rstrip(b"\n")
        service.publish(state, server, encoded, project, digest, sys.stdin.read(), hidden_paths)
    elif command == "hash":
        print(hashlib.sha256(base64.b64decode(sys.stdin.buffer.read().strip(), validate=True)).hexdigest())
    elif command == "storage":
        service.check_storage(json.load(sys.stdin), args[0])
    elif command == "names":
        print(service.names(*args))
    elif command == "retire":
        service.retire(*args)
    elif command == "check":
        print(service.check(*args).decode("ascii"))
    elif command == "start":
        service.start(*args, sys.stdin.buffer.read())
    elif command == "serve":
        service.serve(*args)
    elif command == "request":
        service.request(int(args[0]), int(args[1]), args[2])
    else:
        raise ValueError("unknown host forwarding operation")


if __name__ == "__main__":
    try:
        main(sys.argv[1], sys.argv[2:])
    except (ValueError, OSError, EOFError) as error:
        print(f"Error: host command forwarding: {error}", file=sys.stderr)
        sys.exit(1)
