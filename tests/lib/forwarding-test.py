"""Exercise policy and live Unix-socket requests without requiring Podman."""

import base64
import concurrent.futures
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "src/host/core/resources/forwarding"
LIB = ROOT / "src/container/runtime/lib/jailbox"
sys.path[:0] = [str(HOST), str(LIB)]

from policy import authorize, compile_policy, libc
from forward_protocol import CHUNK, receive, send

GENERATION = "a" * 64
TOOL = (sys.executable, "-I", "-B", str(HOST / "main.py"))


class PolicyTests(unittest.TestCase):
    def test_whole_argument_matching_needs_no_libc_offset_buffer(self):
        rules = compile_policy(b"cmd {{yes|no}}\n")
        with patch.object(libc, "regexec", wraps=libc.regexec) as match:
            authorize(rules, [b"cmd", b"yes"])
        self.assertEqual(match.call_args[0][2:4], (0, None))

    def test_matching(self):
        rules = compile_policy(b"""
# Physical comment.
notify-send \\
    {{.*}}
virsh start {{dev-linux|dev-windows}}
podman run --rm --name test-{{[a-z0-9-]+}} approved-image
sample '--code={{([0-9]{2})}}' "two words" '' \\{\\{literal}} <literal> #
sample {{[[:alpha:]]+}} '{{\\{x\\}}}'
sample {{^z$}}
        """)
        for args in (
            [b"notify-send", b""], [b"notify-send", b"\xff\n\n ;$\x60 "],
            [b"virsh", b"start", b"dev-windows"],
            [b"podman", b"run", b"--rm", b"--name", b"test-123", b"approved-image"],
            [b"sample", b"--code=12", b"two words", b"", b"{{literal}}", b"<literal>", b"#"],
            [b"sample", b"ABC", b"{x}"], [b"sample", b"z"],
        ):
            with self.subTest(args=args):
                authorize(rules, args)
        for args in (
            [b"notify-send"], [b"notify-send", b"a", b"--urgency=critical"],
            [b"virsh", b"start", b"dev-linux\n"], [b"virsh", b"start", b"\ndev-windows"],
            [b"virsh", b"start", b"xdev-linux"], [b"virsh", b"start", b"dev-windowsx"],
            [b"podman", b"run", b"--rm", b"--name", b"test-A", b"approved-image"],
            [b"sample", b"z\n"], [b"sample", b"\xff", b"{x}"], [b"other"],
        ):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, "does not match"):
                authorize(rules, args)

    def test_ambiguous_and_malformed_policy(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            authorize(compile_policy(b"# deny all\n"), [b"cmd"])
        with self.assertRaisesRegex(ValueError, "multiple"):
            authorize(compile_policy(b"cmd {{.*}}\ncmd yes\n"), [b"cmd", b"yes"])
        for policy, line in (
            (b"cmd\\\n x\n", 1), (b"cmd \\\n", 1),
            (b"cmd \\\n# interrupted\n", 2), (b"cmd \\\n 'bad\n", 2),
            (b"cmd \\\n {{[z-a]}}\n", 2),
            (b'cmd "quote\\\n continued"\n', 1), (b"cmd {{a\\\n}}\n", 1),
            (b"cmd {{[0-9]{2}}}\n", 1), (b"cmd {{(a)\\1}}\n", 1),
            (b"cmd {{\\w}}\n", 1), (b"cmd {{a*?}}\n", 1),
            (b"cmd {{a|}}\n", 1), (b"cmd \0\n", 1), (b"/bin/cmd\n", 1),
            (b"cmd " + b"a" * 513, 1),
        ):
            with self.subTest(policy=policy), self.assertRaisesRegex(ValueError, f"line {line}:"):
                compile_policy(policy)


def await_condition(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting for forwarding fixture")


class ServiceTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.tmp = Path(folder.name).resolve()
        self.project = self.tmp / "project"
        (self.project / "data/hidden").mkdir(parents=True)
        self.state = self.tmp / "state"
        self.server = self.tmp / "server"
        self.server.mkdir()
        self.chdir_lock = threading.Lock()
        tools = self.tmp / "tools"
        tools.mkdir()
        self.executable = tools / "forwarded-command"
        shutil.copyfile(ROOT / "tests/fixtures/forwarding/host-command.py", self.executable)
        self.executable.chmod(0o755)
        ssh = tools / "ssh"
        ssh.write_text(f'#!/bin/sh\nprintf "%s\\n" "$PPID" "$$" > "{self.tmp}/tunnel-pids"\nexec /bin/cat >/dev/null\n')
        ssh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        FORWARDING_TEST_HOST="launch-time-host")
        self.policy = self.project / "policy"
        self.policy.write_bytes(
            b"forwarded-command stream\nforwarded-command args '' {{.*}} {{.*}}\n"
            b"forwarded-command directory {{.*}}\nforwarded-command hold\n"
            b"forwarded-command effect one\nforwarded-command effect {{.*}}\n"
            b"forwarded-command terminal\n"
        )
        self.frame = self.tool("capture", self.project, "policy").stdout
        self.digest = self.tool("hash", data=self.frame).stdout.strip().decode()
        manifest = self.tool("describe", self.project, data=self.frame).stdout
        self.tool("publish", self.project, self.state, self.server, self.digest, "data/hidden",
                  data=self.frame + manifest)
        self.addCleanup(self.retire)
        mounts = json.dumps([{"Type": "volume", "RW": True, "Source": str(self.tmp / "home")}]).encode()
        self.tool("start", self.state, GENERATION, "/unused", "fixture", data=mounts)
        try:
            await_condition(lambda: (self.tmp / "tunnel-pids").is_file() and self.check().returncode == 0)
        except AssertionError:
            self.fail((self.state / "ssh.log").read_text() + self.check().stderr.decode())

    def tool(self, *args, data=b"", check=True):
        result = subprocess.run((*TOOL, *map(str, args)), env=self.env, input=data,
                                capture_output=True, timeout=12)
        if check and result.returncode:
            self.fail(result.stderr.decode(errors="replace"))
        return result

    def check(self):
        return self.tool("check", self.state, GENERATION, check=False)

    def retire(self):
        if self.state.exists():
            self.tool("retire", self.state)

    def connect(self):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(5)
        # Short relative socket paths also work in long macOS temp paths.
        with self.chdir_lock:
            cwd = os.getcwd()
            try:
                os.chdir(self.state)
                client.connect("requests.sock")
            finally:
                os.chdir(cwd)
        return client

    def request(self, args, cwd=b""):
        client = self.connect()
        try:
            send(client, b"D", cwd)
            send(client, b"A", base64.b64encode(b"\0".join([b"forwarded-command", *args, b""])))
            return client
        except BaseException:
            client.close()
            raise

    def collect(self, args, cwd=b"", data=b""):
        output, errors = bytearray(), bytearray()
        offset = 0
        with self.request(args, cwd) as client:
            while True:
                kind, value = receive(client)
                if kind == b"C":
                    chunk = data[offset:offset + CHUNK]
                    offset += len(chunk)
                    send(client, b"I", chunk)
                elif kind in (b"O", b"E"):
                    (output if kind == b"O" else errors).extend(value)
                else:
                    return kind, value, bytes(output), bytes(errors)

    def test_streaming_and_snapshot(self):
        self.policy.write_bytes(b"forwarded-command changed\n")
        with concurrent.futures.ThreadPoolExecutor(2) as workers:
            payloads = [bytes(range(256)) * 2048, b"some input\0\xff\n"]
            for payload, result in zip(payloads, workers.map(
                    lambda data: self.collect([b"stream"], data=data), payloads)):
                self.assertEqual(result, (b"X", b"*", payload, b"error\0\xff\n"))
        args = [b"args", b"", b"\xff\n'$x*", b"hello world\n"]
        self.assertEqual(self.collect(args), (b"X", b"\0", b"\0".join(args[1:]) + b"\0", b""))
        self.assertEqual(self.collect([b"terminal"])[2], b"False False False\n")
        shim = self.server / "host-commands/forwarded-command"
        self.assertEqual(shim.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.state / "policy").stat().st_mode & 0o777, 0o600)
        self.assertIn(b'"$@"', shim.read_bytes())

    def test_client(self):
        payload = b"\0\xff" * CHUNK + b"\n"
        adapter = ROOT / "tests/fixtures/forwarding/client.py"
        wrapper = self.tmp / "client"
        installed = ROOT / "src/container/runtime/bin/jailbox-forward-client"
        wrapper.write_text(installed.read_text()
                           .replace("/usr/bin/python3", shlex.quote(sys.executable))
                           .replace("/usr/local/lib/jailbox/encode-argv.sh", shlex.quote(str(LIB / "encode-argv.sh")))
                           .replace("/usr/local/lib/jailbox/forward_client.py", shlex.quote(str(adapter))))
        result = subprocess.run(("/bin/bash", str(wrapper), "--", "forwarded-command", "stream"),
                                cwd=self.project, input=payload, capture_output=True, timeout=10,
                                env=dict(os.environ, FORWARDING_TEST_STATE=str(self.state)))
        self.assertEqual((result.returncode, result.stdout, result.stderr), (42, payload, b"error\0\xff\n"))

    def test_directory_and_direct_denials(self):
        sub = self.project / "sub"
        sub.mkdir()
        (self.project / "marker").write_text("parent path argument\n")
        (self.project / "escape").symlink_to(self.tmp)
        result = self.collect([b"directory", b"../marker"], b"sub")
        self.assertEqual(result, (b"X", b"\0", f"{sub}\nlaunch-time-host\nparent path argument\n".encode(), b""))
        for args, cwd in (
            ([b"effect", b"one"], b""), ([b"effect", b"one", b"extra"], b""),
            ([b"directory", b"marker"], b"escape"), ([b"directory", b"marker"], b"../project"),
            ([b"directory", b"marker"], b"/"), ([b"directory", b"marker"], b"sub/../sub"),
        ):
            self.assertEqual(self.collect(args, cwd)[0], b"F")
        self.assertFalse((self.project / "forwarded-effect").exists())
        with self.connect() as client:
            send(client, b"D")
            send(client, b"A", b"!" * 49152)
            self.assertEqual(receive(client)[0], b"F")
        self.executable.unlink()
        self.assertEqual(self.collect([b"terminal"])[0], b"F")

    def test_hidden_working_directory(self):
        for path in ("data/hidden", "data/hidden/nested", "data/hidden-sibling"):
            directory = self.project / path
            directory.mkdir(exist_ok=True)
            (directory / "marker").write_text("fixture contents")
        (self.project / "data").rename(self.project / "moved")
        # A visible replacement at the old spelling must be usable.
        replacement = self.project / "data/hidden"
        replacement.mkdir(parents=True)
        (replacement / "marker").write_text("new directory")
        for path in (b"moved/hidden", b"moved/hidden/nested", b"moved/hidden/missing"):
            with self.subTest(path=path):
                kind, message, stdout, stderr = self.collect([b"directory", b"marker"], path)
                self.assertEqual((kind, stdout, stderr), (b"F", b"", b""))
                self.assertIn(b"working directory is hidden by HIDDEN_PATHS", message)
        for path, contents in ((b"moved/hidden-sibling", b"fixture contents"),
                               (b"data/hidden", b"new directory")):
            with self.subTest(path=path):
                kind, status, stdout, _ = self.collect([b"directory", b"marker"], path)
                self.assertEqual((kind, status), (b"X", b"\0"))
                self.assertTrue(stdout.endswith(contents))

    def test_pinned_directory_survives_replacement(self):
        sub = self.project / "sub"
        sub.mkdir()
        (sub / "marker").write_text("original")
        code = """
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from service import enter_project
project = Path(sys.argv[2])
info = project.stat()
enter_project({"project": str(project), "identity": [info.st_dev, info.st_ino], "hidden_directories": []}, b"sub")
(project / "sub").rename(project / "moved")
(project / "sub").mkdir()
(project / "sub" / "marker").write_text("replacement")
os.execv(sys.executable, [sys.executable, "-c", "print(open('marker').read())"])
"""
        result = subprocess.run((sys.executable, "-I", "-B", "-c", code, str(HOST), str(self.project)),
                                capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout), (0, b"original\n"), result.stderr)

    def test_generation_binding(self):
        result = self.tool("check", self.state, "b" * 64, check=False)
        self.assertNotEqual(result.returncode, 0)
        challenge, proof = self.check().stdout.split()
        with self.connect() as client:
            send(client, b"P", challenge)
            self.assertEqual(receive(client), (b"P", proof))
        with self.connect() as client:
            send(client, b"P", b"b" * 64)
            self.assertNotEqual(receive(client), (b"P", proof))

    def test_disconnect_cancels_descendants(self):
        with self.request([b"hold"]) as client:
            while True:
                kind, data = receive(client)
                if kind == b"O":
                    child = int(data)
                    break
        def child_gone():
            status = subprocess.run(("ps", "-p", str(child), "-o", "stat="),
                                    capture_output=True, timeout=3).stdout.strip()
            return not status or status.startswith(b"Z")
        await_condition(child_gone)

    def test_stop_cancels_and_removes_owned_state(self):
        with self.request([b"hold"]) as client:
            while receive(client)[0] != b"O":
                pass
            self.retire()
            with self.assertRaises((EOFError, ConnectionResetError)):
                while True:
                    self.assertNotEqual(receive(client)[0], b"X")
        self.assertFalse(self.state.exists())

    def test_abrupt_service_death_interrupts_existing_requests(self):
        with self.request([b"hold"]) as client:
            while receive(client)[0] != b"O":
                pass
            daemon, _ = map(int, (self.tmp / "tunnel-pids").read_text().split())
            os.kill(daemon, 9)
            with self.assertRaises((EOFError, ConnectionResetError)):
                while True:
                    self.assertNotEqual(receive(client)[0], b"X")
        self.assertNotEqual(self.check().returncode, 0)

    def test_transport_death_refuses_health(self):
        with self.request([b"hold"]) as client:
            while receive(client)[0] != b"O":
                pass
            _, transport = map(int, (self.tmp / "tunnel-pids").read_text().split())
            os.kill(transport, 15)
            with self.assertRaises((EOFError, ConnectionResetError)):
                while True:
                    self.assertNotEqual(receive(client)[0], b"X")
        self.assertNotEqual(self.check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
