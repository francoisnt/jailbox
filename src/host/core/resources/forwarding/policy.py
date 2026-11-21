"""Read, parse, and match the byte-oriented host command policy."""

import ctypes as c
import locale
import os
import re
import shutil
import stat
from contextlib import contextmanager

POLICY_LIMIT = 32768
PATTERN_LIMIT = 512
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
NAME = re.compile(rb"[A-Za-z0-9_][A-Za-z0-9_.+-]{0,127}")
INTERVAL = re.compile(rb"\{([0-9]{1,3})(,([0-9]{0,3}))?\}")
SPECIAL = b".[^$()|*+?{\\"
QUANTIFIERS = b"*+?{"
CLASSES = set(b"alnum alpha blank cntrl digit graph lower print punct space upper xdigit".split())

libc = c.CDLL(None)
libc.regcomp.argtypes = (c.c_void_p, c.c_char_p, c.c_int)
libc.regexec.argtypes = (c.c_void_p, c.c_char_p, c.c_size_t, c.c_void_p, c.c_int)
libc.regfree.argtypes = (c.c_void_p,)
libc.regfree.restype = None
locale.setlocale(locale.LC_CTYPE, "C")
locale.setlocale(locale.LC_COLLATE, "C")


class Regex:
    def __init__(self, pattern):
        # regex_t is opaque to Python. This aligned storage exceeds the size
        # of regex_t on the supported Linux and Darwin ABIs.
        self.storage = (c.c_void_p * 128)()
        # Without REG_NEWLINE, POSIX anchors match the argument boundaries
        # and dot still matches newline. Group the full pattern before anchoring.
        result = libc.regcomp(self.storage, b"^(" + pattern + b")$", 1)  # REG_EXTENDED
        if result:
            self.storage = None
            raise ValueError("invalid POSIX extended regular expression")

    def __del__(self):
        if self.storage is not None:
            libc.regfree(self.storage)

    def matches(self, arg):
        # Only ask whether it matched. regmatch_t varies across C libraries.
        result = libc.regexec(self.storage, arg, 0, None, 0)
        if result not in (0, 1):  # REG_NOMATCH
            raise ValueError("regular expression matching failed")
        return result == 0


def read_bracket(pattern, pos):
    pos += 1
    if pattern[pos:pos + 1] == b"^":
        pos += 1
    if pattern[pos:pos + 1] == b"]":
        pos += 1
    while pos < len(pattern):
        if pattern[pos] == ord("]"):
            return pos + 1
        if pattern[pos:pos + 2] in (b"[:", b"[.", b"[="):
            mark = pattern[pos + 1:pos + 2]
            end = pattern.find(mark + b"]", pos + 2)
            if end < 0:
                break
            if mark == b":" and pattern[pos + 2:end] not in CLASSES:
                raise ValueError("unknown POSIX character class")
            pos = end + 2
        else:
            pos += 1
    raise ValueError("unterminated bracket expression")


def check_regex(pattern):
    """Reject extension syntax before passing ERE to the platform library."""
    pos = 0
    groups = [0]
    atom = 0
    branch = False
    while pos < len(pattern):
        char = pattern[pos]
        if char == ord("["):
            pos = read_bracket(pattern, pos)
        elif char == ord("\\"):
            if pos + 1 == len(pattern) or pattern[pos + 1] not in SPECIAL + b"}":
                raise ValueError("non-POSIX regex escape or backreference")
            pos += 2
        elif char == ord("("):
            groups.append(0)
            branch, atom = False, 0
            pos += 1
            continue
        elif char == ord(")"):
            if len(groups) == 1 or not branch:
                raise ValueError("unbalanced or empty regex group")
            atom = groups.pop()
            pos += 1
            groups[-1] += atom
            continue
        elif char == ord("|"):
            if not branch:
                raise ValueError("empty regex alternative")
            branch, atom = False, 0
            pos += 1
            continue
        elif char in QUANTIFIERS:
            if not atom:
                raise ValueError("regex repetition needs an atom")
            count = 1
            if char == ord("{"):
                match = INTERVAL.match(pattern, pos)
                if not match:
                    raise ValueError("invalid regex repetition")
                minimum = int(match[1])
                maximum = int(match[3]) if match[3] else minimum
                if not minimum <= maximum <= 255:
                    raise ValueError("invalid regex repetition bounds")
                count = max(maximum, 1)
                pos = match.end() - 1
            groups[-1] += atom * (count - 1)
            if groups[-1] > 4096:
                raise ValueError("regex repetition is too complex")
            atom = 0
            pos += 1
            continue
        else:
            pos += 1
            if char in b"^$":
                branch, atom = True, 0
                groups[-1] += 1
                continue
        groups[-1] += 1
        atom, branch = 1, True
    if len(groups) != 1 or not branch:
        raise ValueError("empty or unbalanced regex")


def regex_fragment(line, pos):
    start = pos
    while pos < len(line):
        if line[pos:pos + 2] == b"}}":
            pattern = line[start:pos]
            if len(pattern) > PATTERN_LIMIT:
                raise ValueError("argument pattern is too long")
            check_regex(pattern)
            return pattern, pos + 2
        pos += 2 if line[pos] == ord("\\") else 1
    raise ValueError("unclosed regex section")


def tokenize(line, newline):
    args, parts = [], []
    literal = bytearray()
    quote = None
    active = False
    pos = 0
    while pos < len(line):
        char = line[pos]
        if char == ord("\\"):
            pos += 1
            if pos == len(line):
                if newline and not quote and not active:
                    return args, True
                raise ValueError("backslash at end of line must continue at an argument boundary")
            literal.append(line[pos])
        elif line[pos:pos + 2] == b"{{":
            pattern, pos = regex_fragment(line, pos + 2)
            parts.extend(((False, bytes(literal)), (True, pattern)))
            literal.clear()
            active = True
            continue
        elif char in b"'\"" and quote in (None, char):
            quote = None if quote else char
        elif char in b" \t" and not quote:
            if active:
                args.append(parts + [(False, bytes(literal))])
                parts, active = [], False
                literal.clear()
            pos += 1
            continue
        else:
            literal.append(char)
        active = True
        pos += 1
    if quote:
        raise ValueError("unclosed quote")
    if active:
        args.append(parts + [(False, bytes(literal))])
    return args, False


def argument_pattern(parts):
    if sum(len(value) for _, value in parts) > PATTERN_LIMIT:
        raise ValueError("argument pattern is too long")
    if len(parts) == 1:
        return parts[0][1]
    return Regex(b"".join(
        b"(" + value + b")" if regex else re.sub(rb"([.\[\^$()|*+?{\\])", rb"\\\1", value)
        for regex, value in parts
    ))


def compile_policy(contents, reserved=()):
    rules, definition = {}, []
    continued = False
    lines = contents.split(b"\n")
    for number, line in enumerate(lines, 1):
        if number == len(lines) and not line and continued:
            raise ValueError(f"HOST_COMMAND_POLICY line {number - 1}: unfinished continuation")
        try:
            if b"\0" in line:
                raise ValueError("NUL byte in policy")
            if not line.strip(b" \t") or line.lstrip(b" \t").startswith(b"#"):
                if continued:
                    raise ValueError("blank line or comment inside continuation")
                continue
            words, continued = tokenize(line, number < len(lines))
            definition.extend((number, word) for word in words)
            if continued:
                continue
            if not definition:
                raise ValueError("missing executable name")
            number, name_parts = definition[0]
            name = name_parts[0][1]
            if len(name_parts) != 1 or not NAME.fullmatch(name):
                raise ValueError("executable must be a literal command name")
            if name in reserved:
                raise ValueError(f"executable {os.fsdecode(name)} collides with a jailbox runtime helper")
            patterns = []
            for number, parts in definition[1:]:
                patterns.append(argument_pattern(parts))
            rules.setdefault(name, []).append(patterns)
            definition = []
        except ValueError as error:
            raise ValueError(f"HOST_COMMAND_POLICY line {number}: {error}") from None
    return rules


def file_identity(info):
    return info.st_dev, info.st_ino


@contextmanager
def open_directory(root, relative, hidden_directories=()):
    """Follow literal components from a pinned root without following symlinks."""
    parts = relative.split(b"/") if relative else []
    if any(part in (b"", b".", b"..") or b"\0" in part for part in parts):
        raise ValueError("invalid project-relative working directory or policy path")
    fd = os.dup(root) if isinstance(root, int) else os.open(root, DIR_FLAGS)
    try:
        for part in parts:
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            if hidden_directories and file_identity(os.fstat(fd)) in hidden_directories:
                raise ValueError("working directory is hidden by HIDDEN_PATHS")
        yield fd
    finally:
        os.close(fd)


def read_policy(project, path):
    directory, name = os.path.split(os.fsencode(path))
    with open_directory(project, directory) as parent:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(fd, "rb") as file:
            if not stat.S_ISREG(os.fstat(file.fileno()).st_mode):
                raise ValueError("HOST_COMMAND_POLICY must be a readable regular file")
            contents = file.read(POLICY_LIMIT + 1)
    if len(contents) > POLICY_LIMIT:
        raise ValueError("HOST_COMMAND_POLICY exceeds 32768 bytes")
    return contents


def in_tree(path, root):
    return os.path.commonpath((path, root)) == root


def locate_executable(name, project):
    executable = shutil.which(os.fsdecode(name))
    if executable is None or not os.path.isabs(executable):
        raise ValueError(f"host executable {os.fsdecode(name)} is unavailable on an absolute PATH entry")
    path = os.path.realpath(executable)
    if not stat.S_ISREG(os.stat(path).st_mode) or not os.access(path, os.X_OK):
        raise ValueError(f"host executable {os.fsdecode(name)} is unavailable")
    if in_tree(path, project) or in_tree(executable, project):
        raise ValueError(f"host executable {os.fsdecode(name)} resolves inside the project tree")
    return executable, path


def resolve_executables(names, project):
    return {os.fsdecode(name): locate_executable(name, project)[1] for name in names}


def authorize(rules, argv):
    matches = 0
    for patterns in rules.get(argv[0], ()):
        if len(patterns) != len(argv) - 1:
            continue
        if all(value == pattern if isinstance(pattern, bytes) else pattern.matches(value)
               for value, pattern in zip(argv[1:], patterns)):
            matches += 1
            if matches > 1:
                raise ValueError("multiple policy definitions match this request")
    if not matches:
        raise ValueError("request does not match the host command policy")
