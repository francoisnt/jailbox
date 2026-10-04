#!/usr/bin/env python3
"""Append a successful existing full-gate version combination to a CSV list."""
import csv
import datetime as dt
import os
from pathlib import Path
import re
import sys
import tempfile

VERSIONS = ['CODE_VERSION', 'CODIUM_VERSION', 'CODIUM_COMMIT', 'REMOTE_SSH_VERSION', 'OPEN_REMOTE_SSH_VERSION',
            'BASE_IMAGE_DEBIAN', 'BASE_IMAGE_ALPINE', 'BASE_IMAGE_FEDORA',
            'RUNTIME_BASH_VERSION', 'RUNTIME_PODMAN_VERSION']
FIELDS = ['target', 'commit', 'tested_at', *VERSIONS, 'run_url']


def validate(row):
    if set(row) != set(FIELDS) or any(not isinstance(v, str) or not v for v in row.values()):
        raise ValueError('missing compatibility fields')
    if not re.fullmatch(r'master|v[0-9]+\.[0-9]+\.[0-9]+', row['target']):
        raise ValueError('invalid target')
    if not re.fullmatch(r'[0-9a-f]{40}', row['commit']):
        raise ValueError('invalid tested commit')
    if not re.fullmatch(r'[0-9a-f]{40}', row['CODIUM_COMMIT']):
        raise ValueError('invalid VSCodium build commit')
    dt.datetime.strptime(row['tested_at'], '%Y-%m-%dT%H:%M:%SZ')
    if any(not re.fullmatch(r'[a-zA-Z0-9_.:+/-]+', row[key]) for key in VERSIONS):
        raise ValueError('invalid version')
    if not row['run_url'].startswith('https://') or '\n' in row['run_url']:
        raise ValueError('invalid test-run link')


def append(path, row):
    validate(row)
    with open(path, newline='', encoding='utf-8') as stream:
        reader = csv.DictReader(stream, strict=True)
        if reader.fieldnames != FIELDS:
            raise ValueError('invalid compatibility CSV header')
        rows = list(reader)
    for old in rows:
        validate(old)
    # Keep the first successful run of a combination on this exact revision.
    key = ['target', 'commit', *VERSIONS]
    if any(all(old[k] == row[k] for k in key) for old in rows):
        return
    rows.append(row)
    fd, temporary = tempfile.mkstemp(dir=Path(path).parent, prefix='.compatibility-')
    try:
        with os.fdopen(fd, 'w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=FIELDS, lineterminator='\n')
            writer.writeheader()
            writer.writerows(rows)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    try:
        target, path = sys.argv[1:]
        row = {key: os.environ[key] for key in VERSIONS}
        row.update(target=target, commit=os.environ['GITHUB_SHA'],
                   tested_at=os.environ['TESTED_AT'], run_url=os.environ['TEST_RUN_URL'])
        append(path, row)
    except (ValueError, KeyError, OSError, csv.Error) as error:
        raise SystemExit('Could not record compatibility: ' + str(error))
