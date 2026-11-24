#!/usr/bin/env python3
import base64
import hashlib
import io
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/lib"))
sys.path.insert(0, str(ROOT / "tests/fixtures/release"))
import publish_release as publication
import release_notes as notes
from compatibility_history import release_row
from github_release import GitHubRelease

BASE_PINS = {
    "CODE_VERSION": "1.145.0",
    "CODIUM_VERSION": "1.145.7",
    "CODIUM_COMMIT": "a" * 40,
    "REMOTE_SSH_VERSION": "0.128.0",
    "OPEN_REMOTE_SSH_VERSION": "0.6.2",
    "BASE_IMAGE_DEBIAN": "debian:12",
    "BASE_IMAGE_ALPINE": "alpine:3.24",
    "BASE_IMAGE_FEDORA": "fedora:44",
}
OBSERVED = {
    "TESTED_AT": "2026-11-24T11:00:00Z",
    "TEST_RUN_URL": "https://github.com/example/repo/actions/runs/78/attempts/2",
    "RUNTIME_BASH_VERSION": "5.2.21",
    "RUNTIME_PODMAN_VERSION": "5.8.1",
}
HIGHLIGHTS = b"- Upgrade with **this command**.\n\n  `jailbox --version`  \n- Next change.\n\n"
WORKFLOW_ENV = {"RELEASE_EVENT": "push", "GITHUB_OUTPUT": "outputs"}
MATRIX = "<!-- BEGIN GENERATED: tested-matrix -->\n{}\n<!-- END GENERATED: tested-matrix -->\n"
BADGE_URL = "https://github.com/example/repo/actions/workflows/checks.yml"
CI_BADGE = "[![PR checks](" + BADGE_URL + "/badge.svg{})](" + BADGE_URL + ")\n"


class DraftProgressTests(unittest.TestCase):
    def test_terminal_bar_reaches_deadline(self):
        process = Mock(args=["codex"])
        process.poll.return_value = None
        stderr = io.StringIO()
        with patch.object(stderr, "isatty", return_value=True), patch.object(notes.sys, "stderr", stderr), \
                patch.object(notes.time, "monotonic", side_effect=[10, 10, 13, 69.5, 70]), \
                patch.object(notes.selectors, "DefaultSelector") as factory:
            selector = factory.return_value.__enter__.return_value
            selector.select.return_value = []
            with self.assertRaises(subprocess.TimeoutExpired):
                notes.wait_for_draft(process)
        displayed = stderr.getvalue()
        self.assertIn("\rTime budget [--------------------]  0s / 60s", displayed)
        self.assertIn("\rTime budget [#-------------------]  3s / 60s", displayed)
        self.assertTrue(displayed.endswith("\rTime budget [####################] 60s / 60s\n"))
        self.assertEqual(selector.select.call_args.args, (0.5,))

    def test_terminal_log_clears_bar_and_assembles_events(self):
        process = Mock(args=["codex"])
        process.poll.side_effect = [None, None, None, 0, 0, 0]
        stdout_event = [(SimpleNamespace(fileobj=process.stdout, fd=3), 1)]
        stderr_event = [(SimpleNamespace(fileobj=process.stderr, fd=4), 1)]
        output = [b'{"type":"item.started","item":{"id":"x","type":"command_execution",',
                  b'"command":"git status"}}\n', b"Final diagnostic", b""]
        stderr = io.StringIO()
        with patch.object(stderr, "isatty", return_value=True), patch.object(notes.sys, "stderr", stderr), \
                patch.dict(os.environ, TERM="xterm", clear=True), \
                patch.object(notes.time, "monotonic", side_effect=[10, 10, 11, 12, 12.1, 12.2, 12.3]), \
                patch.object(notes.selectors, "DefaultSelector") as factory, \
                patch.object(notes.os, "read", side_effect=output):
            selector = factory.return_value.__enter__.return_value
            selector.select.side_effect = [stdout_event, stdout_event, [], stderr_event, stderr_event, []]
            notes.wait_for_draft(process)
        displayed = stderr.getvalue()
        self.assertIn("\r\x1b[K\x1b[1;36m[CODEX TOOL]\x1b[0m git status\n"
                      "\rTime budget [--------------------]  2s / 60s", displayed)
        self.assertTrue(displayed.endswith("\r\x1b[KFinal diagnostic\n"))


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.work = Path(temp.name)
        self.repo = self.work / "checkout"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        for name in ("GITHUB_OUTPUT", "RELEASE_HIGHLIGHTS", "FIRST_MAJOR", "BUMP", "RELEASE_BRANCH"):
            self.env.pop(name, None)
        self.git("init", "-q", "--initial-branch=master")
        for name in ("scripts/release.sh", "scripts/select-release-request.sh", "scripts/public-api-diff.sh",
                     "scripts/record-compatibility.sh", "scripts/lib/compatibility-history.sh",
                     "scripts/lib/compatibility_history.py", "scripts/lib/dependency_updates.py",
                     "scripts/lib/public-api-values.awk", "scripts/lib/release_notes.py"):
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        self.put("src/public-api.sh", "CONFIG_SCALAR_KEYS=(\n    ORIGINAL\n)\n")
        self.put("README.md", "# Example\n" + CI_BADGE.format(""))
        self.write_pins(BASE_PINS)
        self.put("src/host/frontend/Containerfile.template", "FROM docker.io/library/debian:12\n")
        self.put("docs/development.md", MATRIX.format("fedora:44"))
        self.base = self.commit("First shipped file")
        self.git("tag", "v1.2.3")
        # The top version wins even when another tag points at the same commit.
        self.git("tag", "v0.9.0")
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        CODEX_MARKDOWN=str(self.work / "draft.md"), CODEX_CALLS=str(self.work / "calls"))
        shutil.copyfile(ROOT / "tests/fixtures/release/codex", self.bin / "codex")
        (self.bin / "codex").chmod(0o755)
        (self.work / "draft.md").write_bytes(HIGHLIGHTS)

    def run_cmd(self, *command, check=True, input_text=None, **env):
        stdin = {"stdin": subprocess.DEVNULL} if input_text is None else {"input": input_text}
        return subprocess.run(command, cwd=self.repo, env={**self.env, **env},
                              capture_output=True, text=True, check=check, **stdin)

    def git(self, *args):
        return self.run_cmd("git", *args).stdout.strip()

    def put(self, path, text):
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")

    def write_pins(self, pins):
        self.put("versions.env", "".join(f'{key}="{value}"\n' for key, value in pins.items()))

    def commit(self, subject, *args):
        self.git("add", ".")
        self.git("commit", "-qm", subject, *args)
        return self.git("rev-parse", "HEAD")

    def remote(self):
        remote = self.work / "remote.git"
        self.git("init", "--bare", "--initial-branch=master", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-u", "--tags", "origin", "master")
        return remote

    def render(self, target, *args, **env):
        return self.run_cmd("python3", "scripts/lib/release_notes.py", "render", "v2.0.0",
                            "v1.2.3", self.base, target, *args, **env).stdout

    def test_exact_range_interface_dependencies_and_observations(self):
        pins = dict(BASE_PINS, BASE_IMAGE_DEBIAN="debian:13", BASE_IMAGE_FEDORA="fedora:45")
        self.write_pins(pins)
        self.put("src/host/frontend/Containerfile.template", "FROM docker.io/library/debian:13\n")
        self.put("docs/development.md", MATRIX.format("fedora:45"))
        self.commit("Pin-only commit with generated files")
        self.put("README.md", "# Example\n" + CI_BADGE.format("?event=pull_request"))
        self.put("docs/development.md", MATRIX.format("New CI instructions"))
        self.commit("Documentation updates for maintainers")
        self.put("README.md", "# First launch\n" + CI_BADGE.format("?event=push"))
        self.commit("Explain how to launch jailbox")
        self.put("src/host/core/internal/example/run.go", "package example\n")
        self.commit("Build input changed")
        self.put("tests/example.sh", "# fixture change\n")
        self.put("src/host/core/internal/example/run_test.go", "package example\n")
        self.commit("Test-only commit")
        self.git("switch", "-c", "feature")
        self.put("src/public-api.sh", "CONFIG_SCALAR_KEYS=(\n    REPLACEMENT\n)\n")
        self.commit("Replace configuration key")
        self.git("switch", "master")
        self.git("merge", "--no-ff", "-m", "Merge feature branch", "feature")
        target = self.git("rev-parse", "HEAD")
        self.put("README.md", "# Uncommitted text\n")
        self.put("versions.env", 'BASE_IMAGE_DEBIAN="debian:99"\n')
        draft = self.run_cmd("python3", "scripts/lib/release_notes.py", "draft", self.base, target,
                             CODEX_EXPECT_INTERFACE_CHANGE="- Added `REPLACEMENT`",
                             CODEX_EXPECT_DEPENDENCY_CHANGE="`debian:12` → `debian:13`")
        self.assertEqual(base64.b64decode(draft.stdout), HIGHLIGHTS)
        rendered = self.render(target, "--verified", **OBSERVED)
        self.assertEqual(rendered, self.render(target, "--verified", **OBSERVED))
        self.assertIn("**Breaking** — removed `ORIGINAL`", rendered)
        self.assertIn("Added `REPLACEMENT`", rendered)
        self.assertIn("- Build input changed", rendered)
        self.assertNotIn("Pin-only commit", rendered)
        self.assertNotIn("Documentation updates for maintainers", rendered)
        self.assertIn("- Explain how to launch jailbox", rendered)
        self.assertNotIn("Test-only commit", rendered)
        self.assertNotIn("Merge feature branch", rendered)
        self.assertNotIn("debian:99", rendered)
        deps, verified = rendered.split("## Dependency changes")[1].split("## Verified with")
        self.assertIn("`debian:12` → `debian:13`", deps)
        self.assertNotIn("fedora:", deps)
        self.assertNotIn("1.145.0", deps)
        row = release_row("v2.0.0", target, pins, OBSERVED)
        for key in ("run_url", "tested_at", "CODE_VERSION", "REMOTE_SSH_VERSION", "CODIUM_VERSION", "CODIUM_COMMIT",
                    "OPEN_REMOTE_SSH_VERSION", "BASE_IMAGE_FEDORA", "RUNTIME_BASH_VERSION", "RUNTIME_PODMAN_VERSION"):
            self.assertIn(row[key], verified)
        self.assertIn("Linux runtime", verified)
        self.assertIn("macOS (Intel, Apple Silicon)", verified)
        self.assertIn(f"/compare/v1.2.3...{target}", rendered)

    def test_pin_addition_removal_and_initial_notes(self):
        self.write_pins({key: value for key, value in BASE_PINS.items() if key != "BASE_IMAGE_ALPINE"})
        target = self.commit("Remove proxy pin")
        self.assertIn("removed `alpine:3.24`", self.render(target))
        self.git("tag", "-f", "v1.2.3", target)
        self.base = target
        self.write_pins(BASE_PINS)
        target = self.commit("Add proxy pin")
        self.assertIn("added `alpine:3.24`", self.render(target))
        self.git("tag", "-d", "v1.2.3", "v0.9.0")
        preview = self.run_cmd("bash", "scripts/release.sh", "--dry-run", "--yes", CODEX_TEST_MODE="fail").stdout
        self.assertIn("Selected version: v0.1.0", preview)
        self.assertIn("Initial public release", preview)
        self.assertIn("First shipped file", preview)
        self.assertIn("Pending release CI.", preview)
        self.assertNotIn("## Interface changes", preview)
        self.assertNotIn("Full Git comparison", preview)
        self.assertEqual((self.work / "calls").read_text(), "draft\n")

    def test_local_request_direct_dispatch_and_reused_ref(self):
        self.put("src/jailbox", "update\n")
        summary = "The installer explains how to update an existing sandbox."
        plan_text = "The installer should show which release it installed."
        self.put("plans/archive/fixture.md", f"# Fixture plan\n\n{plan_text}\n")
        target = self.commit("Shipped update", "-m", summary)
        self.env.update(CODEX_EXPECT_SUMMARY=summary, CODEX_EXPECT_PLAN=plan_text, CODEX_REPO=str(self.repo))
        remote = self.remote()
        # Fetching tags may also update remote-tracking refs (including origin/HEAD).
        before = self.git("show-ref", "--heads", "--tags")
        trace = self.work / "preview-git"
        preview = self.run_cmd("bash", "scripts/release.sh", "--dry-run", input_text="minor\n", GIT_TRACE=str(trace))
        self.assertIn("request a higher bump", preview.stdout)
        self.assertIn("Dry run: no release dispatched.", preview.stdout)
        self.assertIn(HIGHLIGHTS.decode(), preview.stdout)
        self.assertEqual((self.work / "calls").read_text(), "draft\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.git("show-ref", "--heads", "--tags"), before)
        self.assertEqual(self.git("ls-remote", "--refs", "origin", "refs/tags/release-request-*"), "")
        self.assertNotIn("git mktag", trace.read_text())
        self.assertNotIn("git push", trace.read_text())

        result = self.run_cmd("bash", "scripts/release.sh", "--yes", "--bump", "minor")
        self.assertIn(HIGHLIGHTS.decode(), result.stdout)
        self.assertIn("Requested minimum bump minor", result.stdout)
        self.assertIn(result.stdout.split("Pushed ", 1)[0], preview.stdout)
        self.assertEqual((self.work / "calls").read_text(), "draft\ndraft\n")
        (_, ref), = (line.split("\t") for line in self.git("ls-remote", "--refs", "origin",
                                                         "refs/tags/release-request-*").splitlines())
        tag = ref.removeprefix("refs/tags/")
        self.git("fetch", "--tags", "origin")
        selected = self.run_cmd("bash", "scripts/select-release-request.sh", REQUEST_TAG=tag, **WORKFLOW_ENV)
        outputs = dict(line.split("=", 1) for line in (self.repo / "outputs").read_text().splitlines())
        self.assertEqual(outputs["version"], "v1.3.0")
        self.assertIn("Requested minimum bump minor", selected.stderr)
        self.assertEqual(outputs["previous_commit"], self.base)
        self.assertEqual(outputs["previous_tag"], "v1.2.3")
        self.assertEqual(outputs["commit"], target)
        self.assertEqual(base64.b64decode(outputs["highlights"]), HIGHLIGHTS)
        self.assertIn(HIGHLIGHTS.decode(), self.render(target, RELEASE_HIGHLIGHTS=outputs["highlights"]))

        direct = self.run_cmd("bash", "scripts/select-release-request.sh",
                              RELEASE_EVENT="workflow_dispatch", GITHUB_OUTPUT="direct")
        self.assertIn("Public API items were unchanged", direct.stderr)
        self.assertIn("highlights=\n", (self.repo / "direct").read_text())
        self.assertIn("Shipped update", self.render(target))
        self.assertEqual((self.work / "calls").read_text(), "draft\ndraft\n")

        # The unchanged request no longer matches after another version ships.
        self.git("tag", "v1.2.4", self.base)
        mismatch = self.run_cmd("bash", "scripts/select-release-request.sh", REQUEST_TAG=tag,
                                **dict(WORKFLOW_ENV, GITHUB_OUTPUT="mismatch"))
        self.assertIn("invalid for this release", mismatch.stderr)
        self.assertIn("highlights=\n", (self.repo / "mismatch").read_text())
        self.git("tag", "-d", "v1.2.4")
        # Same commit and range, but a replacement object at the triggering ref.
        self.git("tag", "-fa", tag, "-m", "Replacement annotation", target)
        self.git("push", "--force", "origin", ref)
        replaced = self.run_cmd("bash", "scripts/select-release-request.sh", REQUEST_TAG=tag,
                                **dict(WORKFLOW_ENV, GITHUB_OUTPUT="replaced"))
        self.assertIn("invalid for this release", replaced.stderr)
        self.assertIn("highlights=\n", (self.repo / "replaced").read_text())
        self.run_cmd("bash", "scripts/select-release-request.sh", "--cleanup", REQUEST_TAG=tag, RELEASE_EVENT="push")
        self.assertTrue(self.git("--git-dir", str(remote), "rev-parse", "--verify", ref))

    def test_offline_and_invalid_codex_drafts(self):
        self.put("src/jailbox", "update\n")
        target = self.commit("Git fallback")
        self.git("remote", "add", "origin", str(self.work / "missing.git"))
        preview = self.run_cmd("bash", "scripts/release.sh", "--dry-run", "--yes")
        self.assertIn("using local tags only", preview.stderr)
        self.assertIn(f"Drafting release highlights with Codex ({notes.CODEX_TIMEOUT}-second limit).", preview.stderr)
        self.assertNotIn("Time budget [", preview.stderr)
        self.assertIn("Selected version: v1.2.4", preview.stdout)
        self.assertEqual(preview.stdout.count(HIGHLIGHTS.decode()), 1)
        self.assertEqual(preview.stderr.count("[CODEX TOOL] git status --short"), 1)
        self.assertIn("Codex fixture startup warning", preview.stderr)
        self.assertNotIn("[CODEX TOOL]", preview.stdout)
        self.assertNotIn("\x1b[", preview.stderr)
        self.assertNotIn("Tool result omitted from terminal", preview.stderr)
        self.assertNotIn("Upgrade with **this command**", preview.stderr)
        fallback = self.run_cmd("bash", "scripts/release.sh", "--dry-run", "--yes", CODEX_TEST_MODE="fail")
        self.assertIn("Git fallback", fallback.stdout)
        self.assertIn("using Git highlights", fallback.stderr)
        self.assertEqual(fallback.stderr.count("Fixture connection lost"), 1)
        with patch.object(notes, "ROOT", self.repo), patch.dict(os.environ, self.env), patch.object(
                notes, "CODEX_TIMEOUT", 0.2):
            for mode, text in (("timeout", HIGHLIGHTS), ("fail", HIGHLIGHTS), ("output", b"   \n"),
                               ("output", b"x" * (notes.MAX_HIGHLIGHT_BYTES + 1))):
                with self.subTest(mode=mode, size=len(text)), patch.dict(os.environ, CODEX_TEST_MODE=mode):
                    (self.work / "draft.md").write_bytes(text)
                    self.assertEqual(notes.draft_highlights(self.base, target), "")
        self.assertIn("Git fallback", self.render(target, RELEASE_HIGHLIGHTS="invalid base64"))

    def test_interrupting_draft_cancels_release(self):
        self.remote()
        pids = self.work / "codex-pids"
        env = dict(self.env, CODEX_TEST_MODE="timeout", CODEX_FIXTURE_PIDS=str(pids))
        child_stopped = False
        with subprocess.Popen(["bash", "scripts/release.sh", "--yes"], cwd=self.repo,
                              env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, start_new_session=True) as process:
            try:
                deadline = time.monotonic() + 10
                while not (self.work / "calls").exists():
                    self.assertIsNone(process.poll(), "release exited before Codex started")
                    self.assertLess(time.monotonic(), deadline, "Codex did not start")
                    time.sleep(0.02)
                draft_pid, codex_pid = map(int, pids.read_text().split())
                # Signal the drafting helper to exercise the shell's status handling too.
                os.kill(draft_pid, signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 130, stdout + stderr)
                self.assertIn("Release cancelled.", stderr)
                self.assertNotIn("Traceback", stderr)
                self.assertNotIn("using Git highlights", stderr)
                self.assertNotIn("## Highlights", stdout)
                with self.assertRaises(ProcessLookupError):
                    os.killpg(codex_pid, 0)
                child_stopped = True
                self.assertEqual(self.git("ls-remote", "--refs", "origin", "refs/tags/release-request-*"), "")
            finally:
                if not child_stopped and pids.exists():
                    _, codex_pid = map(int, pids.read_text().split())
                    try:
                        os.killpg(codex_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)

    def test_publish_retry_and_failed_history_write(self):
        remote = self.remote()
        version = "v2.0.0"
        dist = self.work / "dist"
        dist.mkdir()
        filenames = [f"jailbox-{tag}-{target}.tar.gz"
                     for target in publication.PLATFORMS for tag in (version, "latest")]
        filenames.append("install.sh")
        checksums = []
        for name in filenames:
            data = name.encode("ascii")
            (dist / name).write_bytes(data)
            checksums.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
        (dist / "SHA256SUMS").write_text("".join(checksums))
        assets = publication.release_assets(version, dist)

        def create_tag(tag, commit):
            self.git("--git-dir", str(remote), "update-ref", f"refs/tags/{tag}", commit)

        repo = "repos/example/repo"
        github = GitHubRelease(repo, create_tag)
        with patch.object(publication, "gh_api", github.api):
            first = self.render(self.base, "--verified", **OBSERVED)
            with self.assertRaises(subprocess.CalledProcessError):
                publication.publish(repo, version, self.base, first, assets)
            self.assertEqual(github.tags, {})
            self.assertEqual(github.published, [])
            self.assertEqual(len(github.releases), 1)

            run = dict(OBSERVED, TEST_RUN_URL=OBSERVED["TEST_RUN_URL"].removesuffix("2") + "3")
            second = self.render(self.base, "--verified", **run)
            github.fail_upload = False
            publication.publish(repo, version, self.base, second, assets)
            self.assertEqual(github.published, [2])
            self.assertEqual(list(github.releases), [2])
            self.assertEqual(github.releases[2]["body"], second)
            self.assertNotIn(OBSERVED["TEST_RUN_URL"], github.releases[2]["body"])

        failed = self.run_cmd("bash", "scripts/record-compatibility.sh", version, check=False,
                              TESTED_COMMIT=self.base, **run)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("could not fetch the compatibility branch", failed.stderr)
        self.assertEqual(self.git("--git-dir", str(remote), "rev-parse", f"refs/tags/{version}"), self.base)
        self.assertEqual(github.published, [2])


if __name__ == "__main__":
    unittest.main()
