#!/usr/bin/env python3
"""Validate core ownership and the immediate host-module install inventory."""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
source = root / 'src'
core = source / 'host/core'
errors = []
definitions = {}
modules = sorted(core.rglob('*.sh'))
for path in modules:
    text = path.read_text()
    relative = path.relative_to(core)
    if len(relative.parts) == 1 and relative.name != 'entry.sh':
        errors.append(f'obsolete flat core module: {relative}')
    if relative.name != 'entry.sh' and re.search(r'^source ', text, re.M):
        errors.append(f'module loading outside entry: {relative}')
    for name in re.findall(r'^([a-z_][a-z0-9_]*)\(\)', text, re.M):
        if name in definitions:
            errors.append(f'duplicate core function: {name}')
        definitions[name] = relative

handlers = []
for line in sys.stdin:
    command, handler = line.rstrip('\n').split('\t')
    handlers.append(handler)
    owner = definitions.get(handler)
    if owner is not None and owner.parts[0] != 'commands':
        errors.append(f'command handler outside commands: {command} ({owner})')

for path in (core / 'resources').glob('*.sh'):
    code = '\n'.join(line for line in path.read_text().splitlines()
                     if not line.lstrip().startswith('#'))
    for handler in set(handlers):
        if re.search(r'(?<![\w])' + re.escape(handler) + r'(?![\w])', code):
            errors.append(f'resource calls public handler: {path.name}: {handler}')

installed = set(re.findall(r'^    "(host/core/[^"\n]+)"$',
                          (source / 'install.sh').read_text(), re.M))
expected = {str(path.relative_to(source)) for path in modules}
if installed != expected:
    errors.append('installer core inventory mismatch: ' +
                  repr(sorted(installed ^ expected)))
loaded = set()
for path in (source / 'jailbox', core / 'entry.sh'):
    loaded.update(re.findall(r'^source "\$SCRIPT_DIR/(host/core/[^"\n]+)"',
                             path.read_text(), re.M))
    # Entrypoint branches indent their source statements.
    loaded.update(re.findall(r'^\s+source "\$SCRIPT_DIR/(host/core/[^"\n]+)"',
                             path.read_text(), re.M))
if loaded != expected:
    errors.append('core loading inventory mismatch: ' + repr(sorted(loaded ^ expected)))
if errors:
    sys.exit('\n'.join(errors))
print('Core ownership, loading, and host-module install inventory are complete')
