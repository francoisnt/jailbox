#!/usr/bin/env python3
"""Rules for the compatibility history and recording results in it; all Git remotes are local."""
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(ROOT / 'scripts/lib'))
import compatibility_history as rules  # noqa: E402

SHA = "a" * 40
PINS = {"CODE_VERSION": "1.0.0", "CODIUM_VERSION": "1.0.1", "CODIUM_COMMIT": "c" * 40,
        "REMOTE_SSH_VERSION": "0.1.0", "OPEN_REMOTE_SSH_VERSION": "0.2.0",
        "BASE_IMAGE_DEBIAN": "debian:12", "BASE_IMAGE_ALPINE": "alpine:3.24",
        "BASE_IMAGE_FEDORA": "fedora:41", "GO_SERIES": "1.27"}


def release_row(tag, kind="release", result="pass", **changes):
    row = dict.fromkeys(rules.RELEASE_FIELDS, "")
    row.update({key: PINS[key] for key in PINS if key in row})
    row.update(target=tag, kind=kind, commit=SHA, tested_at="2026-01-01T00:00:00Z", result=result,
               RUNTIME_BASH_VERSION="5.2", RUNTIME_PODMAN_VERSION="4.9", run_url="https://example.invalid/run")
    row.update(changes)
    return row


def empty(path):
    with path.open('w', newline='') as out:
        csv.writer(out, lineterminator='\n').writerow(rules.RELEASE_FIELDS)


class ReleaseCheckTests(unittest.TestCase):
    editors = {key: PINS[key] for key in rules.EDITOR_KEYS}

    def test_target_is_the_highest_release_row(self):
        rows = [release_row("v0.9.0"), release_row("v0.10.0"), release_row("v0.11.0", kind="editor-check")]
        self.assertEqual(rules.release_target(rows), "v0.10.0")
        self.assertEqual(rules.release_target([]), "")

    def test_pass_or_fail_ends_checks_but_error_does_not(self):
        newer = dict(self.editors, CODE_VERSION="1.1.0")
        rows = [release_row("v1.0.0")]
        self.assertTrue(rules.release_check_done(rows, "v1.0.0", self.editors))
        self.assertFalse(rules.release_check_done(rows, "v1.0.0", newer))
        for result, done in (("error", False), ("fail", True), ("pass", True)):
            check = release_row("v1.0.0", kind="editor-check", result=result, CODE_VERSION="1.1.0")
            self.assertEqual(rules.release_check_done(rows + [check], "v1.0.0", newer), done)

    def test_unsupported_go_ends_checks_of_that_tag(self):
        go = release_row("v1.0.0", kind="editor-check", result="fail", RUNTIME_BASH_VERSION="",
                         RUNTIME_PODMAN_VERSION="", **{key: "" for key in rules.EDITOR_KEYS + ["CODIUM_COMMIT"]})
        rules.validate(go)
        self.assertTrue(rules.unsupported_release_recorded([go], "v1.0.0"))
        self.assertFalse(rules.unsupported_release_recorded([go], "v1.0.1"))
        self.assertFalse(rules.unsupported_release_recorded([release_row("v1.0.0")], "v1.0.0"))


class ClassificationTests(unittest.TestCase):
    def test_release_check(self):
        self.assertEqual(rules.classify_check({"code": "pass", "codium": "pass"}), "pass")
        self.assertEqual(rules.classify_check({"code": "test-fail", "codium": "error"}), "fail")
        self.assertEqual(rules.classify_check({"code": "pass", "codium": "error"}), "error")
        self.assertEqual(rules.classify_check({}), "error")


class OutcomeTests(unittest.TestCase):
    def test_each_editor_job_output_or_error(self):
        self.assertEqual(rules.editor_outcomes({"CODE_OUTCOME": "test-fail", "CODIUM_OUTCOME": "pass"}),
                         {"code": "test-fail", "codium": "pass"})
        # A job that stopped before classifying left no output.
        for value in ("", "passed", "pass\n"):
            with self.subTest(value=value):
                self.assertEqual(rules.editor_outcomes({"CODE_OUTCOME": value, "CODIUM_OUTCOME": "pass"})["code"],
                                 "error")
        self.assertEqual(rules.editor_outcomes({}), {"code": "error", "codium": "error"})


class HistoryTests(unittest.TestCase):
    def write(self, directory, name, rows=()):
        path = Path(directory) / name
        with path.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=rules.RELEASE_FIELDS, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        return path

    def test_release_rows_must_be_complete_but_checks_may_leave_fields_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write(tmp, "releases.csv")
            rules.append(path, release_row("v1.0.0"))
            with self.assertRaises(ValueError):
                rules.append(path, release_row("v1.0.1", RUNTIME_BASH_VERSION=""))
            with self.assertRaises(ValueError):
                rules.append(path, release_row("v1.0.1", kind="other"))
            rules.append(path, release_row("v1.0.0", kind="editor-check", result="error", RUNTIME_BASH_VERSION=""))
            self.assertEqual([row["kind"] for row in rules.read_rows(path)], ["release", "editor-check"])

    def test_recorded_ignores_when_and_where_a_result_ran(self):
        rows = [release_row("v1.0.0", kind="editor-check", result="fail")]
        self.assertTrue(rules.recorded(rows, dict(rows[0], tested_at="2026-02-01T00:00:00Z",
                                                  run_url="https://example.invalid/other")))
        self.assertFalse(rules.recorded(rows, dict(rows[0], result="error")))


class RecorderTests(unittest.TestCase):
    def test_recording_uses_the_history_branch_and_retries_without_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, remote = root / 'checkout', root / 'remote.git'
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')

            def git(*args):
                return subprocess.check_output(['git', *args], cwd=repo, env=env, text=True,
                                               stderr=subprocess.DEVNULL).strip()

            def record(*args, **changes):
                return subprocess.run(['bash', 'scripts/record-compatibility.sh', *args], cwd=repo,
                                      env=dict(env, **changes), capture_output=True, text=True)

            def history(name):
                git('fetch', 'origin', 'compatibility:refs/remotes/origin/compatibility')
                return list(csv.DictReader(git('show', 'origin/compatibility:' + name).splitlines()))

            def remote_head(branch):
                return subprocess.check_output(['git', '--git-dir', str(remote), 'rev-parse', branch],
                                               env=env, text=True).strip()

            subprocess.run(['git', 'init', '--bare', '--initial-branch=master', str(remote)], check=True,
                           env=env, capture_output=True)
            subprocess.run(['git', 'clone', str(remote), str(repo)], check=True, env=env, capture_output=True)
            # The history lives on its own branch with unrelated history.
            git('checkout', '--orphan', 'compatibility')
            empty(repo / 'releases.csv')
            (repo / 'master.csv').write_text('historical results\n')
            git('add', '.')
            git('commit', '-m', 'history fixture')
            git('push', 'origin', 'compatibility')
            git('checkout', '--orphan', 'master')
            git('rm', '-rqf', '.')
            (repo / 'scripts/lib').mkdir(parents=True)
            for name in ['scripts/record-compatibility.sh', 'scripts/lib/dependency_updates.py',
                         'scripts/lib/compatibility-history.sh', 'scripts/lib/compatibility_history.py']:
                (repo / name).write_bytes((ROOT / name).read_bytes())
            pins = ''.join(k + '="' + ('b' * 40 if k == 'CODIUM_COMMIT' else 'debian:12' if k.startswith('BASE')
                                       else '1.2.3') + '"\n'
                           for k in rules.VERSIONS if not k.startswith('RUNTIME_'))
            (repo / 'versions.env').write_text(pins)
            git('add', '.')
            git('commit', '-m', 'test fixture')
            tested = git('rev-parse', 'HEAD')
            (repo / 'unrelated.txt').write_text('keep me\n')
            git('add', 'unrelated.txt')
            git('commit', '-m', 'unrelated change')
            git('push', 'origin', 'master')
            master = remote_head('master')
            git('checkout', '--detach', tested)
            env.update(TESTED_COMMIT=tested, TESTED_AT='2026-10-04T00:00:00Z',
                       TEST_RUN_URL='https://example.invalid/run/1', RUNTIME_BASH_VERSION='5.2.1',
                       RUNTIME_PODMAN_VERSION='5.0.0')
            for args, values, status, message in [
                    (['invalid'], {}, 2, 'Invalid compatibility target'),
                    (['master'], {}, 2, 'Invalid compatibility target'),
                    (['v1.0.0'], dict(TESTED_COMMIT='0' * 40), 1, 'Checkout does not match')]:
                failed = record(*args, **values)
                self.assertEqual(failed.returncode, status)
                self.assertIn(message, failed.stderr)

            # A release's own row records the checkout's pins once.
            heads = []
            for _ in range(2):
                result = record('v1.0.0')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                heads.append(remote_head('compatibility'))
            self.assertEqual(heads[0], heads[1])
            rows = history('releases.csv')
            self.assertEqual(len(rows), 1)
            self.assertEqual((rows[0]['target'], rows[0]['kind'], rows[0]['commit'], rows[0]['result']),
                             ('v1.0.0', 'release', tested, 'pass'))
            self.assertEqual(rows[0]['CODIUM_COMMIT'], 'b' * 40)
            self.assertEqual(remote_head('master'), master)

            # Published-release editor checks append only to releases.csv.
            row = dict.fromkeys(rules.RELEASE_FIELDS, '')
            row.update(target='v1.0.0', kind='editor-check', commit=tested, tested_at='2026-10-05T00:00:00Z',
                       result='error', run_url='https://example.invalid/run/2')
            row_file = root / 'editor-check'
            row_file.write_text(json.dumps(row))
            result = record('--editor-check', str(row_file))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(history('releases.csv')[-1]['result'], 'error')
            self.assertEqual(git('show', 'origin/compatibility:master.csv'), 'historical results')
            row_file.write_text(json.dumps(dict(row, kind='release')))
            self.assertNotEqual(record('--editor-check', str(row_file)).returncode, 0)

            # A policy/hook rejection must fail once, without claiming a race.
            hook = repo / '.git/hooks/pre-push'
            shutil.copyfile(ROOT / 'tests/fixtures/compatibility-push.sh', hook)
            hook.chmod(0o755)
            env.update(PUSH_MODE='reject', PUSH_LOG=str(root / 'push.log'))
            rejected = record('v2.0.0')
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('compatibility branch was unchanged', rejected.stderr)
            self.assertNotIn('branch changed; retrying', rejected.stderr)
            self.assertEqual((root / 'push.log').read_text().splitlines(), ['push'])
            # Advance the remote during the push itself to exercise the retry.
            other = root / 'other'
            subprocess.run(['git', 'clone', '--branch', 'compatibility', str(remote), str(other)], check=True,
                           env=env, capture_output=True)
            (root / 'push.log').write_text('')
            env.update(PUSH_MODE='race', PUSH_OTHER=str(other), PUSH_MOVED=str(root / 'moved'))
            raced = record('v2.0.0')
            self.assertEqual(raced.returncode, 0, raced.stdout + raced.stderr)
            self.assertIn('compatibility branch changed; retrying', raced.stderr)
            self.assertEqual((root / 'push.log').read_text().splitlines(), ['push', 'push'])
            self.assertEqual([r['target'] for r in history('releases.csv') if r['kind'] == 'release'], ['v1.0.0', 'v2.0.0'])
            self.assertIn('Concurrent fixture commit', git('log', '--format=%s', 'origin/compatibility'))
            # Automation never commits to master.
            self.assertEqual(remote_head('master'), master)

    def test_missing_history_branch_fails_without_touching_master(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, remote = root / 'checkout', root / 'remote.git'
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
            subprocess.run(['git', 'init', '--bare', '--initial-branch=master', str(remote)], check=True,
                           env=env, capture_output=True)
            subprocess.run(['git', 'clone', str(remote), str(repo)], check=True, env=env, capture_output=True)
            (repo / 'scripts/lib').mkdir(parents=True)
            for name in ['scripts/record-compatibility.sh', 'scripts/lib/dependency_updates.py',
                         'scripts/lib/compatibility-history.sh', 'scripts/lib/compatibility_history.py']:
                (repo / name).write_bytes((ROOT / name).read_bytes())
            subprocess.run(['git', 'add', '.'], cwd=repo, check=True, env=env)
            subprocess.run(['git', 'commit', '-qm', 'fixture'], cwd=repo, check=True, env=env)
            subprocess.run(['git', 'push', '-q', 'origin', 'master'], cwd=repo, check=True, env=env,
                           capture_output=True)
            row = dict.fromkeys(rules.RELEASE_FIELDS, '')
            row.update(target='v1.0.0', kind='editor-check', commit='a' * 40, tested_at='2026-10-05T00:00:00Z',
                       result='error', run_url='https://example.invalid/run/2')
            (root / 'row').write_text(json.dumps(row))
            result = subprocess.run(['bash', 'scripts/record-compatibility.sh', '--editor-check', str(root / 'row')],
                                    cwd=repo, env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('could not fetch the compatibility branch', result.stderr)
            heads = subprocess.check_output(['git', '--git-dir', str(remote), 'for-each-ref', '--format=%(refname)'],
                                            env=env, text=True).split()
            self.assertEqual(heads, ['refs/heads/master'])


if __name__ == '__main__':
    unittest.main()
