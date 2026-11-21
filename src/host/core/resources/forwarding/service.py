"""Own the SSH forwarding connection and its host command process groups."""

import fcntl
import hashlib
import hmac
import json
import os
import queue
import re
import secrets
import selectors
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

from policy import (
    authorize, compile_policy, file_identity, in_tree, locate_executable,
    open_directory, read_policy, resolve_executables,
)

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parents[3] / "container/runtime"
sys.path.insert(0, str(RUNTIME / "lib/jailbox"))
from argv_codec import ARGV_LIMIT, decode_argv
from forward_protocol import CHUNK, receive, send, write_all

PYTHON = (sys.executable, "-I", "-B", str(HERE / "main.py"))
CONTROL = "control.sock"
REQUESTS = "requests.sock"
LOCK = "lock"
MANIFEST = "manifest"
SNAPSHOT = "policy"
LOG = "ssh.log"
SHIMS = "host-commands"
GENERATION = re.compile(r"[0-9a-f]{64}")
MAX_REQUESTS = 32
TERMINATION_GRACE = 0.35


def inspect_state(state):
    """Check the reserved directory completely before using or deleting it."""
    info = os.lstat(state)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("unsafe host forwarding state directory")
    os.chdir(state)
    types = {CONTROL: stat.S_ISSOCK, REQUESTS: stat.S_ISSOCK, LOCK: stat.S_ISREG,
             MANIFEST: stat.S_ISREG, SNAPSHOT: stat.S_ISREG, LOG: stat.S_ISREG}
    for path in os.listdir():
        info = os.lstat(path)
        if (path not in types or not types[path](info.st_mode)
                or info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError("unsafe file in host forwarding state")


def lock_state(create=False):
    flags = os.O_RDWR | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT
    try:
        fd = os.open(LOCK, flags, 0o600)
    except FileNotFoundError:
        if create:
            raise
        return None, True
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd, True
    except BlockingIOError:
        return fd, False
    except BaseException:
        os.close(fd)
        raise


def control_request(kind, timeout=1):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(timeout)
        sock.connect(CONTROL)
        send(sock, kind)
        return receive(sock, 64)


def retire(state):
    inspect_state(state)
    deadline = time.monotonic() + 6
    requested = False
    while True:
        fd, idle = lock_state()
        if idle:
            # This process holds the lock until it exits. A crashed owner has
            # no recoverable PIDs. Its SSH pipe closed with the process.
            for path in os.listdir():
                os.unlink(path)
            os.chdir("..")
            os.rmdir(state)
            return
        os.close(fd)
        if time.monotonic() >= deadline:
            raise ValueError("could not verify shutdown of the owned host forwarding service")
        if not requested:
            try:
                response, detail = control_request(b"S", timeout=3)
                if response == b"F":
                    raise ValueError(detail.decode("ascii"))
                requested = response == b"S" and not detail
            except (OSError, EOFError):
                pass
        time.sleep(0.05)


def probe_response(generation, challenge, manifest):
    key = bytes.fromhex(manifest["probe_key"])
    return hmac.new(key, generation.encode("ascii") + challenge, hashlib.sha256).hexdigest().encode("ascii")


def check(state, generation):
    inspect_state(state)
    fd, idle = lock_state()
    if fd is not None:
        os.close(fd)
    if idle or control_request(b"H") != (b"H", generation.encode("ascii")):
        raise ValueError("host forwarding service is unavailable or belongs to a different container")
    challenge = secrets.token_hex(32).encode("ascii")
    return challenge + b" " + probe_response(generation, challenge, load_manifest())


def capture(project, path):
    return read_policy(os.fsencode(project), path)


def prepare(project, encoded, umask):
    from base64 import b64decode
    contents = b64decode(encoded.strip(), validate=True)
    # These commands run as part of sandbox startup, SSH readiness or
    # editor bootstrapping with the sandbox PATH.
    required = b"awk bash chmod curl find grep id mktemp mv python3 rm sh ssh sshd ssh-keygen stat tar wget base64"
    reserved = (*required.split(), *(os.fsencode(path.name) for path in (RUNTIME / "bin").iterdir()))
    if in_tree(str(RUNTIME.resolve()), project) or in_tree(str(HERE), project):
        raise ValueError("the jailbox installation must be outside the forwarded project tree")
    signal.alarm(3)
    rules = compile_policy(contents, reserved)
    executables = resolve_executables(rules, project)
    ssh, _ = locate_executable(b"ssh", project)
    signal.alarm(0)
    info = os.stat(project, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError("cannot pin the host project root")
    return {
        "project": project, "identity": file_identity(info),
        "executables": executables, "hash": hashlib.sha256(contents).hexdigest(),
        "probe_key": secrets.token_hex(32), "ssh": ssh, "python": sys.executable, "umask": umask,
    }


def hidden_directory_identities(project, identity, hidden_paths):
    identities = []
    with open_directory(project, b"") as root:
        if file_identity(os.fstat(root)) != tuple(identity):
            raise ValueError("host project root has changed")
        for path in hidden_paths:
            parent, name = os.path.split(os.fsencode(path))
            with open_directory(root, parent) as directory:
                info = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                identities.append(file_identity(info))
            elif not stat.S_ISREG(info.st_mode):
                raise ValueError(f"HIDDEN_PATHS path changed before forwarding was published: {path}")
    return identities


def publish(state, server, encoded, project, expected_hash, prepared, hidden_paths):
    from base64 import b64decode
    contents = b64decode(encoded.strip(), validate=True)
    if hashlib.sha256(contents).hexdigest() != expected_hash:
        raise ValueError("inconsistent host forwarding policy snapshot")
    manifest = json.loads(prepared)
    if manifest["hash"] != expected_hash or manifest["project"] != project:
        raise ValueError("inconsistent host forwarding policy preparation")
    # Use the effective mask paths immediately before container creation.
    manifest["hidden_directories"] = hidden_directory_identities(project, manifest["identity"], hidden_paths)
    os.mkdir(state, 0o700)
    os.chdir(state)
    Path(MANIFEST).write_text(json.dumps(manifest), encoding="ascii")
    Path(SNAPSHOT).write_bytes(contents)
    shim_root = Path(server) / SHIMS
    shim_root.mkdir(mode=0o755)
    for name in manifest["executables"]:
        path = shim_root / name
        # Names have the literal executable grammar and cannot quote or split.
        path.write_text(
            f'#!/bin/bash\nexec /usr/local/bin/jailbox-forward-client -- {name} "$@"\n', encoding="ascii"
        )
        path.chmod(0o755)
    shim_root.chmod(0o755)


def names(state):
    inspect_state(state)
    return " ".join(load_manifest()["executables"])


def load_manifest():
    return json.loads(Path(MANIFEST).read_text(encoding="ascii"))


def check_storage(manifest, source):
    if not isinstance(source, str) or not os.path.isabs(source) or any(ord(byte) < 32 for byte in source):
        raise ValueError("unknown writable mount source for host forwarding")
    root = os.path.realpath(source)
    for name, path in manifest["executables"].items():
        if in_tree(path, root):
            raise ValueError(f"host executable {name} resolves inside a container-writable mount")
    for directory in (str(HERE), str(RUNTIME.resolve())):
        if in_tree(directory, root):
            raise ValueError("the jailbox installation lies inside a container-writable mount")
    for helper in ("ssh", "python"):
        if in_tree(os.path.realpath(manifest[helper]), root) or in_tree(manifest[helper], root):
            raise ValueError(f"the host {helper} helper lies inside a container-writable mount")


def check_mount_sources(manifest, raw_mounts):
    mounts = json.loads(raw_mounts)
    if not isinstance(mounts, list):
        raise ValueError("invalid mount inspection for host forwarding")
    has_home = False
    for mount in mounts:
        if not isinstance(mount, dict) or not isinstance(mount.get("RW"), bool):
            raise ValueError("invalid mount inspection for host forwarding")
        if not mount["RW"]:
            continue
        has_home = has_home or mount.get("Type") == "volume"
        check_storage(manifest, mount.get("Source"))
    if not has_home:
        raise ValueError("could not establish sandbox home storage for host forwarding")


def start(state, generation, config, host, mounts):
    inspect_state(state)
    if not GENERATION.fullmatch(generation):
        raise ValueError("invalid forwarding container identity")
    check_mount_sources(load_manifest(), mounts)
    fd, idle = lock_state(create=True)
    try:
        if not idle or os.path.lexists(CONTROL) or os.path.lexists(REQUESTS):
            raise ValueError("host forwarding service state already exists")
        log = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            subprocess.Popen(
                (*PYTHON, "serve", generation, config, host), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=log, pass_fds=(fd,), start_new_session=True,
            )
        finally:
            os.close(log)
    finally:
        os.close(fd)


def listen(path):
    sock = socket.socket(socket.AF_UNIX)
    try:
        sock.bind(path)
        sock.listen(MAX_REQUESTS)
        return sock
    except BaseException:
        sock.close()
        raise


def signal_child(process, sig, group=False):
    # Do not send signals to a reaped group leader's PID. The tracked child
    # retains its identity until the owner polls or waits for it.
    if process.returncode is None:
        try:
            (os.killpg if group else os.kill)(process.pid, sig)
        except ProcessLookupError:
            pass


def stop_children(children):
    for process in children:
        signal_child(process, signal.SIGTERM)
    deadline = time.monotonic() + TERMINATION_GRACE + 0.1
    while any(process.poll() is None for process in children) and time.monotonic() < deadline:
        time.sleep(0.02)
    for process in children:
        signal_child(process, signal.SIGKILL, group=True)
    for process in children:
        process.wait(timeout=1)


def serve(generation, config, host):
    stopping = False
    workers = set()

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)
    ssh = None
    retire_reply = None
    ssh_path = load_manifest()["ssh"]
    lifetime_read, lifetime_write = os.pipe()
    try:
        with listen(CONTROL) as control, listen(REQUESTS) as requests, selectors.DefaultSelector() as poll:
            ssh = subprocess.Popen((
                ssh_path, "-F", config, "-T", "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=3", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2",
                "-o", "ControlMaster=no", "-o", "ForwardAgent=no",
                "-R", "/run/jailbox-forward.sock:./" + REQUESTS,
                host, "/usr/local/bin/jailbox-forward-client --hold",
            ), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, start_new_session=True)
            poll.register(control, selectors.EVENT_READ)
            poll.register(requests, selectors.EVENT_READ)
            while not stopping and ssh.poll() is None:
                workers = {worker for worker in workers if worker.poll() is None}
                for key, _ in poll.select(0.1):
                    resource = key.fileobj
                    with resource.accept()[0] as conn:
                        if resource is control:
                            conn.settimeout(0.2)
                            try:
                                kind, _ = receive(conn, 0)
                                if kind == b"S":
                                    stopping = True
                                    retire_reply = conn.dup()
                                    break
                                elif kind == b"H" and not stopping and ssh.poll() is None:
                                    send(conn, b"H", generation.encode("ascii"))
                            except (OSError, EOFError, ValueError):
                                pass
                        elif not stopping and len(workers) < MAX_REQUESTS:
                            fd = conn.fileno()
                            workers.add(subprocess.Popen(
                                (*PYTHON, "request", str(fd), str(lifetime_read), generation),
                                pass_fds=(fd, lifetime_read), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                start_new_session=True,
                            ))
                        else:
                            conn.settimeout(0.05)
                            try:
                                send(conn, b"F", b"service busy or stopping")
                            except OSError:
                                pass
    finally:
        os.close(lifetime_read)
        os.close(lifetime_write)
        if ssh is not None:
            workers.add(ssh)
        kind, detail = b"S", b""
        try:
            stop_children(workers)
        except (OSError, subprocess.TimeoutExpired):
            kind, detail = b"F", b"could not terminate all host forwarding processes"
            raise
        finally:
            if ssh is not None:
                ssh.stdin.close()
            if retire_reply is not None:
                with retire_reply:
                    try:
                        send(retire_reply, kind, detail)
                    except OSError:
                        pass


def cancel_request(_signal=None, _frame=None):
    # The worker is the live process-group leader. Keep it alive until the
    # whole group has had a bounded chance to terminate.
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, signal.SIG_IGN)
    os.killpg(os.getpgrp(), signal.SIGTERM)
    time.sleep(TERMINATION_GRACE)
    os.killpg(os.getpgrp(), signal.SIGKILL)


def enter_project(manifest, relative):
    project = os.fsencode(manifest["project"])
    hidden_directories = {tuple(identity) for identity in manifest["hidden_directories"]}
    with open_directory(project, b"") as root:
        if file_identity(os.fstat(root)) != tuple(manifest["identity"]):
            raise ValueError("host project root has changed")
        with open_directory(root, relative, hidden_directories) as directory:
            os.fchdir(directory)
    if not in_tree(os.getcwdb(), project):
        raise ValueError("working directory lies outside the host project")


def watch_service(lifetime, sock, interrupted):
    # SSH can keep existing channels open after the remote hold command
    # exits. This descriptor closes with the service even after SIGKILL.
    try:
        os.read(lifetime, 1)
    finally:
        interrupted.set()
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        os.close(lifetime)


def request(fd, lifetime, generation):
    with socket.socket(fileno=fd) as sock:
        service_lost = threading.Event()
        threading.Thread(target=watch_service, args=(lifetime, sock, service_lost), daemon=True).start()
        signal.alarm(4)
        try:
            kind, relative = receive(sock, 4096)
            if kind == b"P" and GENERATION.fullmatch(relative.decode("ascii", "replace")):
                send(sock, b"P", probe_response(generation, relative, load_manifest()))
                return
            if kind != b"D":
                raise ValueError("expected forwarding working directory")
            kind, frame = receive(sock, ARGV_LIMIT)
            if kind != b"A":
                raise ValueError("expected forwarding arguments")
            argv = decode_argv(frame)
            manifest = load_manifest()
            data = Path(SNAPSHOT).read_bytes()
            if hashlib.sha256(data).hexdigest() != manifest["hash"]:
                raise ValueError("forwarding policy snapshot has changed")
            # SIGALRM bounds platform regex execution even inside libc.
            signal.setitimer(signal.ITIMER_REAL, 1)
            authorize(compile_policy(data), argv)
            enter_project(manifest, relative)
            if service_lost.is_set():
                return
            signal.alarm(0)
        except (OSError, ValueError) as error:
            send(sock, b"F", str(error).encode("utf-8", "backslashreplace"))
            return
        interrupted = threading.Event()

        def cancel(_signal=None, _frame=None):
            interrupted.set()
            cancel_request()

        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, cancel)
        # Keep the launch environment and argv intact. Only the executable
        # used by execve and the already-pinned working directory are mapped.
        try:
            os.umask(manifest["umask"])
            child = subprocess.Popen(
                argv, executable=manifest["executables"][os.fsdecode(argv[0])],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
        except OSError as error:
            send(sock, b"F", f"host executable could not start: {error.strerror}".encode())
            return
        relay(sock, child, interrupted, service_lost, cancel)


def relay(sock, child, interrupted, service_lost, cancel):
    send_lock = threading.Lock()
    pending = queue.Queue(1)
    credit = threading.Event()
    done = threading.Event()

    def frame(kind, data=b""):
        with send_lock:
            send(sock, kind, data)

    def disconnect():
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def push_input():
        try:
            with child.stdin:
                while True:
                    credit.set()
                    frame(b"C")
                    data = pending.get()
                    if not data:
                        return
                    write_all(child.stdin.fileno(), data)
        except BrokenPipeError:
            # The host command can exit or close stdin while still writing.
            pass
        except OSError:
            disconnect()

    def pull_output(pipe, kind):
        try:
            with pipe:
                while True:
                    data = os.read(pipe.fileno(), CHUNK)
                    if not data:
                        return
                    frame(kind, data)
        except OSError:
            disconnect()

    def publish_result():
        result = child.wait()
        for thread in outputs:
            thread.join()
        try:
            if not interrupted.is_set() and not service_lost.is_set():
                frame(b"X", bytes([result if result >= 0 else 128 - result]))
                done.set()
        except OSError:
            pass
        finally:
            disconnect()

    outputs = [threading.Thread(target=pull_output, args=(pipe, kind), daemon=True)
               for pipe, kind in ((child.stdout, b"O"), (child.stderr, b"E"))]
    threads = outputs + [threading.Thread(target=push_input, daemon=True),
                         threading.Thread(target=publish_result, daemon=True)]
    for thread in threads:
        thread.start()
    try:
        input_closed = False
        while True:
            kind, data = receive(sock)
            if kind != b"I" or input_closed or not credit.is_set():
                raise ValueError("unexpected forwarding input")
            credit.clear()
            pending.put_nowait(data)
            input_closed = not data
    except (EOFError, OSError, ValueError, queue.Full):
        if not done.is_set() and not interrupted.is_set():
            cancel()
