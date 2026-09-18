#!/usr/bin/env python3
"""Bounded PTY driver for the public shell command (portable and real SSH)."""

import argparse
import errno
import fcntl
import os
import select
import signal
import struct
import subprocess
import termios
import time
from pathlib import Path


READY = b"__jailbox_login_shell__"
PROBE = (
    b"unset HISTFILE; if [[ $- == *i* ]] && shopt -q login_shell; then "
    b"printf '__jailbox_login_%s__\\n' shell; else exit 91; fi; exit 0\n"
)


class Terminal:
    def __init__(self, command, cwd, output, stdin_pipe=False, stdout_pipe=False):
        self.master, self.slave = os.openpty()
        self.resize(31, 97)
        # No echo: typed commands must not masquerade as execution evidence.
        modes = termios.tcgetattr(self.slave)
        modes[3] &= ~termios.ECHO
        termios.tcsetattr(self.slave, termios.TCSANOW, modes)
        self.modes = termios.tcgetattr(self.slave)
        self.data = bytearray()
        self.output = Path(output)
        self.error = open(str(output) + ".stderr", "wb")
        self.deadline = time.monotonic() + 60

        def child_terminal():
            os.setsid()
            fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)

        try:
            self.process = subprocess.Popen(
                command, cwd=cwd, stdin=subprocess.PIPE if stdin_pipe else self.slave,
                stdout=subprocess.PIPE if stdout_pipe else self.slave,
                stderr=self.error, preexec_fn=child_terminal, pass_fds=(self.slave,),
                env=dict(os.environ, TERM="xterm"),
            )
        except BaseException:
            self.error.close()
            os.close(self.master)
            os.close(self.slave)
            raise
        self.readers = [self.master]
        if stdout_pipe:
            self.readers.append(self.process.stdout.fileno())
        for fd in self.readers:
            os.set_blocking(fd, False)

    def resize(self, rows, columns):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def send(self, data):
        os.write(self.master, data)

    def pump(self):
        if time.monotonic() >= self.deadline:
            raise AssertionError("terminal test timed out")
        ready, _, _ = select.select(self.readers, [], [], 0.05)
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError as error:
                if error.errno not in (errno.EIO, errno.EAGAIN):
                    raise
                data = b""
            if data:
                self.data.extend(data)
            elif fd != self.master:
                self.readers.remove(fd)

    def until(self, token):
        start = len(self.data)
        while token not in self.data[start:]:
            self.pump()
            if self.process.poll() is not None and token not in self.data[start:]:
                raise AssertionError("shell exited before " + repr(token))

    def request(self, command, token):
        self.send(command + b"\n")
        self.until(token)

    def finish(self, expected=None, restored=False):
        while self.process.poll() is None:
            self.pump()
        self.pump()
        status = self.process.returncode
        if expected is not None and status != expected:
            raise AssertionError(f"expected status {expected}, received {status}")
        if restored and termios.tcgetattr(self.slave) != self.modes:
            raise AssertionError("SSH did not restore local terminal modes")
        return status

    def close(self):
        # Also kill foreground jobs in the local fixture on assertion failure.
        if self.process.poll() is None:
            try:
                foreground = os.tcgetpgrp(self.slave)
                if foreground > 0:
                    os.killpg(foreground, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=5)
        self.output.with_suffix(self.output.suffix + ".stdout").write_bytes(self.data)
        self.error.close()
        os.close(self.master)
        os.close(self.slave)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def observe(args):
    with Terminal(args.command, args.cwd, args.output, args.stdin_pipe, args.stdout_pipe) as tty:
        if tty.process.stdin:
            tty.process.stdin.close()
        else:
            tty.send(PROBE)
        status = tty.finish()
        diagnostic = Path(args.output + ".stderr").read_bytes()
        if b"read-only observer attempted mutation" in diagnostic:
            raise AssertionError("shell attempted lifecycle mutation")
        if args.expect == "allow":
            if status != 0 or READY not in tty.data:
                raise AssertionError("compatible sandbox did not open an interactive login shell")
        elif status == 0 or tty.data or not diagnostic:
            raise AssertionError("invalid shell refusal")


def exercise(args):
    # Run against real SSH. Startup fixture prints initial cwd/proxy, then
    # deliberately changes them; the interactive shell must retain the changes.
    with Terminal(args.command, args.cwd, args.output + ".terminal") as tty:
        tty.until(b"__profile_complete__")
        expected = b"__initial__/home/jailbox/project|" + args.proxy.encode() + b"__"
        if expected not in tty.data:
            raise AssertionError("login profile did not receive initial cwd/proxy")
        if args.proxy:
            for name in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy"):
                value = "localhost,127.0.0.1" if name.lower() == "no_proxy" else args.proxy
                expected = f"__environment__{name}={value}__".encode()
                if expected not in tty.data:
                    raise AssertionError("login profile lost " + name)
        tty.request(
            b"unset HISTFILE; [[ $- == *i* ]] && shopt -q login_shell && "
            b"[[ $PWD == /tmp && $HTTP_PROXY == profile-proxy && $PATH == /profile-bin:* ]] "
            b"&& printf '__customizations_%s__\\n' kept",
            b"__customizations_kept__",
        )
        tty.request(b"stty size", b"31 97")
        tty.resize(43, 113)
        tty.request(b"stty size", b"43 113")
        tty.request(
            b"bash -c 'trap \"exit 73\" INT; printf \"__foreground_ready__\\n\"; "
            b"while :; do sleep 1; done'; printf '__interrupt_status_%s__\\n' \"$?\"",
            b"__foreground_ready__",
        )
        tty.send(b"\x03")
        tty.until(b"__interrupt_status_73__")
        tty.send(b"exit 42\n")
        tty.finish(42, restored=True)
    for status in (0, 1, 126, 127, 130, 255):
        with Terminal(args.command, args.cwd, args.output + f".exit-{status}") as tty:
            tty.until(b"__profile_complete__")
            tty.send(f"unset HISTFILE; exit {status}\n".encode())
            tty.finish(status, restored=True)
    for name, action in (("direct-int", signal.SIGINT), ("direct-term", signal.SIGTERM), ("disconnect", None)):
        with Terminal(args.command, args.cwd, args.output + "." + name) as tty:
            tty.until(b"__profile_complete__")
            # Confirm the client is in terminal mode before interrupting it.
            tty.request(b"unset HISTFILE; printf '__client_%s__\\n' ready", b"__client_ready__")
            if action is None:
                # OpenSSH's normal interactive disconnect escape, at a new line.
                tty.send(b"\n~.")
            else:
                os.kill(tty.process.pid, action)
            if tty.finish(restored=True) == 0:
                raise AssertionError("interrupted/disconnected SSH reported success")


def main():
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--expect", choices=("allow", "refuse"), default="allow")
    parser.add_argument("--stdin-pipe", action="store_true")
    parser.add_argument("--stdout-pipe", action="store_true")
    parser.add_argument("--exercise", action="store_true")
    parser.add_argument("--proxy", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command.pop(0)
    if not args.command:
        parser.error("a command is required")
    try:
        (exercise if args.exercise else observe)(args)
    except (AssertionError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"FAIL: {error}; terminal logs: {args.output}.*\n")


if __name__ == "__main__":
    main()
