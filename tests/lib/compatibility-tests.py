#!/usr/bin/env python3
"""Focused tests of the passive version lists; all Git remotes are local."""
import csv
import importlib.util
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('record', ROOT / 'scripts/lib/record-compatibility.py')
record = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record)


def empty(path):
    with path.open('w', newline='') as out:
        csv.writer(out, lineterminator='\n').writerow(record.FIELDS)


def row(**changes):
    value = dict.fromkeys(record.VERSIONS, '1.2.3')
    value.update(CODIUM_COMMIT='b' * 40, target='master', commit='a' * 40, tested_at='2026-10-04T00:00:00Z',
                 run_url='https://example.invalid/run/1')
    value.update(changes)
    return value


class CompatibilityTests(unittest.TestCase):
    def test_append_deduplicates_and_preserves_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'list.csv'
            empty(path)
            record.append(path, row())
            original = path.read_bytes()
            record.append(path, row(tested_at='2026-10-05T00:00:00Z', run_url='https://example.invalid/run/2'))
            self.assertEqual(path.read_bytes(), original)
            record.append(path, row(CODE_VERSION='2.0.0'))
            record.append(path, row(target='v1.0.0'))
            record.append(path, row(commit='b' * 40))
            record.append(path, row(CODIUM_COMMIT='c' * 40))
            with path.open() as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 5)
            self.assertEqual(rows[0], row())

    def test_missing_or_corrupt_data_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'list.csv'
            with self.assertRaises(OSError): record.append(path, row())
            path.write_text('wrong,header\n')
            with self.assertRaises(ValueError): record.append(path, row())
            self.assertEqual(path.read_text(), 'wrong,header\n')
            empty(path)
            for changes in [dict(commit='unknown'), dict(RUNTIME_PODMAN_VERSION=''),
                            dict(tested_at='not-a-date'), dict(target='unknown'), dict(CODIUM_COMMIT='unknown')]:
                with self.assertRaises(ValueError): record.append(path, row(**changes))
            with path.open('a', newline='') as out:
                csv.DictWriter(out, fieldnames=record.FIELDS).writerow(row(commit='corrupt'))
            corrupt = path.read_bytes()
            with self.assertRaisesRegex(ValueError, 'invalid tested commit'):
                record.append(path, row())
            self.assertEqual(path.read_bytes(), corrupt)

    def test_reporting_keeps_moved_master_and_retries_without_duplicates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, remote = root / 'checkout', root / 'remote.git'
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                       GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=repo, env=env, text=True, stderr=subprocess.DEVNULL).strip()
            subprocess.run(['git', 'init', '--bare', '--initial-branch=master', str(remote)], check=True, env=env, capture_output=True)
            subprocess.run(['git', 'clone', str(remote), str(repo)], check=True, env=env, capture_output=True)
            (repo / 'scripts/lib').mkdir(parents=True)
            (repo / 'compatibility').mkdir()
            for name in ['scripts/record-compatibility.sh', 'scripts/lib/record-compatibility.py']:
                (repo / name).write_bytes((ROOT / name).read_bytes())
            for name in ['master', 'releases']: empty(repo / 'compatibility' / (name + '.csv'))
            pins = ''.join(k + '="' + ('b' * 40 if k == 'CODIUM_COMMIT' else '1.2.3') + '"\n'
                           for k in record.VERSIONS if not k.startswith('RUNTIME_'))
            (repo / 'versions.env').write_text(pins)
            git('add', '.')
            git('commit', '-m', 'test fixture')
            tested = git('rev-parse', 'HEAD')
            (repo / 'unrelated.txt').write_text('keep me\n')
            git('add', 'unrelated.txt')
            git('commit', '-m', 'unrelated change')
            git('push', 'origin', 'master')
            git('checkout', '--detach', tested)
            env.update(GITHUB_SHA=tested, TESTED_AT='2026-10-04T00:00:00Z',
                       TEST_RUN_URL='https://example.invalid/run/1', RUNTIME_BASH_VERSION='5.2.1',
                       RUNTIME_PODMAN_VERSION='5.0.0', JAILBOX_CODE_VERSION='2.0.0', JAILBOX_CODIUM_COMMIT='c' * 40)
            for target, values, status, message in [
                    ('invalid', env, 2, 'Invalid compatibility target'),
                    ('master', dict(env, GITHUB_SHA='0' * 40), 1, 'Checkout does not match')]:
                failed = subprocess.run(['bash', 'scripts/record-compatibility.sh', target], cwd=repo,
                                        env=values, capture_output=True, text=True)
                self.assertEqual(failed.returncode, status)
                self.assertIn(message, failed.stderr)
            for target in ['master', 'v1.0.0']:
                if target == 'v1.0.0': env.pop('JAILBOX_CODIUM_COMMIT')
                for _ in range(2):
                    result = subprocess.run(['bash', 'scripts/record-compatibility.sh', target], cwd=repo, env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    git('fetch', 'origin', 'master')
                    head = git('rev-parse', 'origin/master')
                    if _ == 0: first = head
                    else: self.assertEqual(head, first)
                name = 'master' if target == 'master' else 'releases'
                rows = list(csv.DictReader(git('show', 'origin/master:compatibility/' + name + '.csv').splitlines()))
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]['commit'], tested)
                self.assertEqual(rows[0]['CODE_VERSION'], '2.0.0')
                self.assertEqual(rows[0]['CODIUM_COMMIT'], ('c' if target == 'master' else 'b') * 40)
            self.assertEqual(git('show', 'origin/master:unrelated.txt'), 'keep me')
            self.assertEqual(git('show', 'origin/master:versions.env'), pins.strip())
            # A policy/hook rejection must fail once, without claiming a race.
            hook = repo / '.git/hooks/pre-push'
            shutil.copyfile(ROOT / 'tests/fixtures/compatibility-push.sh', hook)
            hook.chmod(0o755)
            env.update(PUSH_MODE='reject', PUSH_LOG=str(root / 'push.log'))
            rejected = subprocess.run(['bash', 'scripts/record-compatibility.sh', 'v2.0.0'],
                                      cwd=repo, env=env, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('master was unchanged', rejected.stderr)
            self.assertNotIn('master changed; retrying', rejected.stderr)
            self.assertEqual((root / 'push.log').read_text().splitlines(), ['push'])
            # Advance the remote during the push itself to exercise the retry.
            other = root / 'other'
            subprocess.run(['git', 'clone', str(remote), str(other)], check=True, env=env, capture_output=True)
            (root / 'push.log').write_text('')
            env.update(PUSH_MODE='race', PUSH_OTHER=str(other), PUSH_MOVED=str(root / 'moved'))
            raced = subprocess.run(['bash', 'scripts/record-compatibility.sh', 'v2.0.0'],
                                   cwd=repo, env=env, capture_output=True, text=True)
            self.assertEqual(raced.returncode, 0, raced.stdout + raced.stderr)
            self.assertIn('master changed; retrying', raced.stderr)
            self.assertEqual((root / 'push.log').read_text().splitlines(), ['push', 'push'])
            git('fetch', 'origin', 'master')
            rows = list(csv.DictReader(git('show', 'origin/master:compatibility/releases.csv').splitlines()))
            self.assertEqual([r['target'] for r in rows], ['v1.0.0', 'v2.0.0'])
            self.assertIn('Concurrent fixture commit', git('log', '--format=%s', 'origin/master'))



if __name__ == '__main__':
    unittest.main()
