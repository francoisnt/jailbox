"""Forward one command, or check the generation on the reverse SSH socket."""

import os
import socket
import sys
import threading
from pathlib import Path

# Isolated Python ignores user modules and PYTHONPATH.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from forward_protocol import CHUNK, PROJECT, SOCKET, receive, send, write_all


def stream_input(sock, credit):
    try:
        while True:
            credit.acquire()
            data = os.read(0, CHUNK)
            send(sock, b"I", data)
            if not data:
                return
    except OSError:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def forward(sock, frame):
    cwd = os.getcwdb()
    if cwd == PROJECT:
        relative = b""
    elif cwd.startswith(PROJECT + b"/"):
        relative = cwd[len(PROJECT) + 1:]
    else:
        raise ValueError("forwarded commands must run inside the sandbox project")
    if len(relative) > 4096:
        raise ValueError("forwarded working directory is too long")

    send(sock, b"D", relative)
    send(sock, b"A", frame)
    credit = threading.Semaphore(0)
    threading.Thread(target=stream_input, args=(sock, credit), daemon=True).start()
    while True:
        kind, data = receive(sock)
        if kind == b"C" and not data:
            credit.release()
        elif kind in (b"O", b"E"):
            write_all(1 if kind == b"O" else 2, data)
        elif kind == b"X" and len(data) == 1:
            return data[0]
        elif kind == b"F":
            write_all(2, b"Error: host command forwarding: " + data + b"\n")
            return 125
        else:
            raise ValueError("invalid forwarding response")


def main(args):
    if args == ["--hold"]:
        # Parent service owns the pipe feeding SSH. EOF retires the tunnel
        # even if the service dies before it can explicitly stop its SSH child.
        while os.read(0, CHUNK):
            pass
        return 0
    with socket.socket(socket.AF_UNIX) as sock:
        if len(args) == 2 and args[0] == "--probe":
            sock.settimeout(3)
            sock.connect(SOCKET)
            send(sock, b"P", args[1].encode("ascii"))
            kind, data = receive(sock, 64)
            if kind != b"P" or len(data) != 64:
                raise ValueError("invalid forwarding readiness response")
            write_all(1, data + b"\n")
            return 0
        if len(args) != 2 or args[0] != "--":
            raise ValueError("expected a forwarded command")
        try:
            sock.connect(SOCKET)
        except OSError:
            raise ValueError("service unavailable. Run 'jailbox stop' then 'jailbox up'") from None
        return forward(sock, os.fsencode(args[1]))


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("Error: host command forwarding interrupted. Command outcome is unknown.", file=sys.stderr)
        sys.exit(130)
    except (EOFError, OSError):
        sys.exit("Error: host command forwarding connection interrupted. Command outcome is unknown.")
    except ValueError as error:
        sys.exit(f"Error: {error}")
