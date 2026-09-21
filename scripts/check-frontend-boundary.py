#!/usr/bin/env python3
"""Reject direct frontend references to private core implementation/state."""
import pathlib
import re
import shlex
import sys

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent / 'src'

def code(path):
    return '\n'.join(line for line in path.read_text().splitlines()
                     if not line.lstrip().startswith('#'))

def functions(text):
    return set(re.findall(r'^([a-z_][a-z0-9_]*)\(\)', text, re.M))

def shell_words(text):
    # Keep quoted data distinct from shell words. This is a source lint,
    # not a parser for arbitrary/dynamic Bash.
    lexer = shlex.shlex(text, posix=False, punctuation_chars=';&|()\n')
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    return list(lexer)

def written_state(text):
    words = shell_words(text)
    writes = set()
    declaration = False
    printf_target = False
    for index, word in enumerate(words):
        if word in (';', '&&', '||', '|', '(', ')', '()', '{', '}') or '\n' in word:
            declaration = False
        if word in ('declare', 'local', 'export', 'readonly', 'typeset'):
            declaration = True
            continue
        target = word.strip("'\"") if declaration or printf_target else word
        match = re.match(r'^([A-Z][A-Z0-9_]*)(?:\[[^]]*\])?(?:\+?=|$)', target)
        if match and (declaration or printf_target or '=' in target):
            writes.add(match.group(1))
        printf_target = word == '-v' and index > 0 and words[index - 1] == 'printf'
    return writes

core = '\n'.join(code(p) for p in (root / 'host/core').rglob('*.sh'))
files = sorted((root / 'host/frontend').rglob('*.sh'))
public = code(root / 'public.sh') + '\n' + code(root / 'host/api-support.sh') + '\n' + code(root / 'host/cli.sh')
# These two names deliberately have independent implementations in each layer.
# New frontend declarations must not silently exempt additional core helpers.
private_functions = functions(core) - functions(public) - {'die', 'run_validate'}
private_state = set()
for line in core.splitlines():
    if re.match(r'^(?:declare\s|[A-Z][A-Z0-9_]*=)', line):
        private_state.update(written_state(line))
# Machine configuration globals are private even when keys are public metadata.
for declaration in ('CONFIG_SCALAR_KEYS', 'CONFIG_ARRAY_KEYS'):
    match = re.search(r'^' + declaration + r'=\((.*?)\)', public, re.S | re.M)
    if not match:
        sys.exit(f'Frontend boundary: missing public declaration: {declaration}')
    body = match.group(1)
    private_state.update(re.findall(r'\b[A-Z][A-Z0-9_]*\b', body))
errors = []
for path in files:
    text = code(path)
    writes = written_state(text)
    for token in sorted(private_functions | private_state):
        if re.search(r'(?<![\w])' + re.escape(token) + r'(?![\w])', text):
            # File key strings and case labels are data; only shell references
            # or assignments to machine globals cross the boundary.
            if token in private_state and token not in writes and not re.search(
                    r'\$(?:\{[!#]?)?' + token + r'\b', text):
                continue
            errors.append(f'{path.relative_to(root)}: private core reference: {token}')
    # Quoted diagnostic text is data; a quoted executable in a command
    # position still invokes the engine.
    words = shell_words(text)
    for index, word in enumerate(words):
        previous = words[index - 1] if index else '\n'
        command_position = (previous in {'if', 'then', 'do', 'command', 'exec', 'env', 'sudo', '!'}
                            or any(char in previous for char in '\n;|&({'))
        if word == 'podman' or (word in {"'podman'", '"podman"'} and command_position):
            errors.append(f'{path.relative_to(root)}: private core command: podman')
            break
    for marker in ('host/core/', '/ssh-generation', 'jailbox/projects/'):
        if marker in text:
            errors.append(f'{path.relative_to(root)}: private core path: {marker}')
if errors:
    sys.exit('\n'.join(errors))
print('Frontend boundary: public CLI only')
