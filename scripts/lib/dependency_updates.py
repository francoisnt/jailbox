#!/usr/bin/env python3
"""Rules for dependency updates: the pinned keys, their formats, and which updates are pending."""
import argparse
import json
from pathlib import Path
import re
import tarfile

# Dependencies in table order; each update moves one of them. VSCodium's
# version and build commit always move together.
DEPENDENCIES = [
    ("code", ["CODE_VERSION"]),
    ("remote-ssh", ["REMOTE_SSH_VERSION"]),
    ("open-remote-ssh", ["OPEN_REMOTE_SSH_VERSION"]),
    ("codium", ["CODIUM_VERSION", "CODIUM_COMMIT"]),
    ("debian", ["BASE_IMAGE_DEBIAN"]),
    ("alpine", ["BASE_IMAGE_ALPINE"]),
    ("fedora", ["BASE_IMAGE_FEDORA"]),
    ("go", ["GO_SERIES"]),
]
EDITOR_VERSION = r"[0-9]+(\.[0-9]+){1,3}"
IMAGE_VERSIONS = {"alpine": r"[1-9][0-9]*\.(0|[1-9][0-9]*)", "debian": r"[1-9][0-9]*",
                  "fedora": r"[1-9][0-9]*"}
FORMATS = {
    "CODE_VERSION": EDITOR_VERSION,
    "REMOTE_SSH_VERSION": EDITOR_VERSION,
    "OPEN_REMOTE_SSH_VERSION": EDITOR_VERSION,
    "CODIUM_VERSION": EDITOR_VERSION,
    "CODIUM_COMMIT": r"[0-9a-f]{40}",
    "GO_SERIES": r"1\.(0|[1-9][0-9]*)",
    **{f"BASE_IMAGE_{image.upper()}": f"{image}:{pattern}" for image, pattern in IMAGE_VERSIONS.items()},
}
KEY_ORDER = [key for _, keys in DEPENDENCIES for key in keys]
EDITOR_KEYS = ["CODE_VERSION", "CODIUM_VERSION", "REMOTE_SSH_VERSION", "OPEN_REMOTE_SSH_VERSION"]
SHA = re.compile(r"[0-9a-f]{40}")


def parse_update(text, partial=False):
    """Return {KEY: VALUE} in table order, refusing anything malformed.

    partial allows a VSCodium update without its build commit, which only an
    error row may record.
    """
    if not isinstance(text, str) or not text or text != text.strip() or "  " in text:
        raise ValueError(f"invalid update text: {text!r}")
    values = {}
    for token in text.split(" "):
        key, separator, value = token.partition("=")
        if not separator or key not in FORMATS:
            raise ValueError(f"unknown update key in {token!r}")
        if key in values:
            raise ValueError(f"{key} appears twice")
        if not re.fullmatch(FORMATS[key], value):
            raise ValueError(f"invalid value for {key}: {value!r}")
        values[key] = value
    for name, keys in DEPENDENCIES:
        present = [key for key in keys if key in values]
        if present and len(present) != len(keys) and not (partial and present == keys[:1]):
            raise ValueError(f"the {name} update needs {' and '.join(keys)}")
    return {key: values[key] for key in KEY_ORDER if key in values}


def format_update(values):
    return " ".join(f"{key}={values[key]}" for key in KEY_ORDER if key in values)


def version_tuple(value):
    return tuple(int(part) for part in re.split(r"[.]", value))


def newer(key, newest, pinned):
    if key.startswith("BASE_IMAGE_"):
        newest, pinned = newest.split(":", 1)[1], pinned.split(":", 1)[1]
    return version_tuple(newest) > version_tuple(pinned)


def read_env(path):
    """Read KEY="value" or KEY=value lines; the files are data, never evaluated."""
    return parse_env(Path(path).read_text(encoding="utf-8"))


def parse_env(text):
    values = {}
    for line in text.splitlines():
        match = re.match(r'([A-Z][A-Z0-9_]*)=(?:"([^"]*)"|([^"\s#]*)(?:\s|$))', line)
        if match:
            values[match[1]] = match[2] if match[2] is not None else match[3]
    return values


def pending_updates(newest, pins):
    """Updates whose newest version is newer than the pin, as identity pairs."""
    result = []
    for name, keys in DEPENDENCIES:
        key = keys[0]
        if key not in newest:
            raise ValueError(f"no newest version for {key}")
        if not re.fullmatch(FORMATS[key], newest[key]) or not re.fullmatch(FORMATS[key], pins.get(key, "")):
            raise ValueError(f"invalid newest or pinned value for {key}")
        if newer(key, newest[key], pins[key]):
            result.append(f"{key}={newest[key]}")
    return result


def command_pending(args):
    pins = read_env(args.versions)
    pins["GO_SERIES"] = args.go_series
    for update in pending_updates(read_env(args.newest), pins):
        print(update)


def command_codium_pin(args):
    pins = read_env(args.versions)
    values = []
    for key in ("CODIUM_VERSION", "CODIUM_COMMIT"):
        value = pins.get(key, "")
        if not re.fullmatch(FORMATS[key], value):
            raise ValueError(f"invalid pinned value for {key}: {value!r}")
        values.append(value)
    print(*values)


def command_codium_commit(args):
    # Read just the editor metadata. Never extract an upstream archive to disk.
    with tarfile.open(args.archive, "r:gz") as archive:
        products = [member for member in archive if member.isfile()
                    and member.name.removeprefix("./") == "resources/app/product.json"]
        if len(products) != 1:
            raise ValueError("the VSCodium archive has no single product.json")
        with archive.extractfile(products[0]) as stream:
            product = json.load(stream)
    commit = product.get("commit", "") if isinstance(product, dict) else ""
    if not isinstance(commit, str) or not SHA.fullmatch(commit):
        raise ValueError("the VSCodium archive names no valid build commit")
    print(commit)


def command_complete(args):
    values = parse_update(args.update, partial=True)
    if "CODIUM_VERSION" in values and "CODIUM_COMMIT" not in values:
        if not args.codium_commit:
            raise ValueError("the VSCodium build commit is unknown")
        values["CODIUM_COMMIT"] = args.codium_commit
    print(format_update(parse_update(format_update(values))))


def command_parse(args):
    values = parse_update(args.update)
    for key, value in values.items():
        print(f"{key}\t{value}")


def command_image_pattern(args):
    print(f"^{IMAGE_VERSIONS[args.image]}$")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pending = commands.add_parser("pending")
    for name in ("newest", "versions", "go-series"):
        pending.add_argument(f"--{name}", required=True)
    pending.set_defaults(handler=command_pending)
    pin = commands.add_parser("codium-pin")
    pin.add_argument("versions")
    pin.set_defaults(handler=command_codium_pin)
    codium = commands.add_parser("codium-commit")
    codium.add_argument("archive")
    codium.set_defaults(handler=command_codium_commit)
    complete = commands.add_parser("complete")
    complete.add_argument("--update", required=True)
    complete.add_argument("--codium-commit", default="")
    complete.set_defaults(handler=command_complete)
    parse = commands.add_parser("parse")
    parse.add_argument("update")
    parse.set_defaults(handler=command_parse)
    pattern = commands.add_parser("image-pattern")
    pattern.add_argument("image", choices=sorted(IMAGE_VERSIONS))
    pattern.set_defaults(handler=command_image_pattern)
    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        raise SystemExit(f"Error: {error}")


if __name__ == "__main__":
    main()
