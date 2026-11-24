#!/usr/bin/env python3
"""Rules for the compatibility history: its record format and the published-release editor check."""
import argparse
import csv
import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
import tempfile

# Pin keys, update text, and data-only reading of versions.env.
import dependency_updates as updates

RESULTS = {"pass", "fail", "error"}
KINDS = {"release", "editor-check"}
VERSIONS = ["CODE_VERSION", "CODIUM_VERSION", "CODIUM_COMMIT", "REMOTE_SSH_VERSION",
            "OPEN_REMOTE_SSH_VERSION", "BASE_IMAGE_DEBIAN", "BASE_IMAGE_ALPINE",
            "BASE_IMAGE_FEDORA", "RUNTIME_BASH_VERSION", "RUNTIME_PODMAN_VERSION"]
RELEASE_FIELDS = ["target", "kind", "commit", "tested_at", "result", *VERSIONS, "run_url"]
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SHA = updates.SHA
VERSION_VALUE = re.compile(r"[a-zA-Z0-9_.:+/-]+")
EDITOR_KEYS = updates.EDITOR_KEYS


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, strict=True)
        if reader.fieldnames != RELEASE_FIELDS:
            raise ValueError(f"invalid header in {path}")
        rows = list(reader)
    for row in rows:
        validate(row)
    return rows


def release_target(releases):
    tags = [row["target"] for row in releases if row["kind"] == "release"]
    return max(tags, key=lambda tag: updates.version_tuple(tag[1:]), default="")


def release_check_done(releases, tag, editors):
    """A pass or fail for these editor versions ends editor tests."""
    return any(row["target"] == tag and row["result"] in ("pass", "fail")
               and all(row[key] == editors[key] for key in EDITOR_KEYS)
               for row in releases)


def unsupported_release_recorded(releases, tag):
    return any(row["target"] == tag and row["kind"] == "editor-check"
               and row["result"] == "fail" and not row["CODE_VERSION"] for row in releases)


def classify_check(outcomes):
    """Combine both editors' outcomes. A missing report is an error."""
    values = list(outcomes.values())
    if not values:
        return "error"
    if all(value == "pass" for value in values):
        return "pass"
    if "test-fail" in values:
        return "fail"
    return "error"


def validate(row):
    if set(row) != set(RELEASE_FIELDS) or any(not isinstance(value, str) for value in row.values()):
        raise ValueError("missing compatibility fields")
    if not TAG.fullmatch(row["target"]):
        raise ValueError("invalid target")
    if row["kind"] not in KINDS:
        raise ValueError("invalid kind")
    if not SHA.fullmatch(row["commit"]):
        raise ValueError("invalid tested commit")
    dt.datetime.strptime(row["tested_at"], "%Y-%m-%dT%H:%M:%SZ")
    if row["result"] not in RESULTS:
        raise ValueError("invalid result")
    # A release's own row comes from complete gates; other rows leave
    # unobserved fields empty.
    complete = row["kind"] == "release"
    for key in VERSIONS:
        if not row[key]:
            if complete:
                raise ValueError(f"missing {key}")
        elif not VERSION_VALUE.fullmatch(row[key]):
            raise ValueError("invalid version")
    if row["CODIUM_COMMIT"] and not SHA.fullmatch(row["CODIUM_COMMIT"]):
        raise ValueError("invalid VSCodium build commit")
    if not row["run_url"].startswith("https://") or "\n" in row["run_url"]:
        raise ValueError("invalid test-run link")


def recorded(rows, row):
    """Whether ROWS already hold this result: the same row apart from when and where it ran."""
    key = [field for field in RELEASE_FIELDS if field not in ("tested_at", "run_url")]
    return any(all(old[k] == row[k] for k in key) for old in rows)


def append(path, row):
    validate(row)
    rows = read_rows(path)
    # Keep the first record of an identical result on this exact revision.
    if recorded(rows, row):
        return
    rows.append(row)
    fd, temporary = tempfile.mkstemp(dir=Path(path).parent, prefix=".compatibility-")
    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=RELEASE_FIELDS, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def tested_versions(pins, update_values):
    """Version columns for pins with an update applied; unknown stays empty."""
    row = {key: pins.get(key, "") for key in VERSIONS if not key.startswith("RUNTIME_")}
    row.update({key: value for key, value in update_values.items() if key in row})
    if "CODIUM_VERSION" in update_values and "CODIUM_COMMIT" not in update_values:
        row["CODIUM_COMMIT"] = ""
    return row


def now():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def editor_outcomes(env):
    """Each editor job's outcome from its job output. A job that stopped
    before classifying its tests left none, which is an error."""
    outcomes = {}
    for editor in ("code", "codium"):
        value = env.get(f"{editor.upper()}_OUTCOME", "")
        outcomes[editor] = value if value in ("pass", "test-fail", "error") else "error"
    return outcomes


def command_check_row(args):
    go_unsupported = os.environ["RELEASE_GO_VERSION"] == "unsupported"
    if go_unsupported:
        result = "fail"
        versions = tested_versions(updates.read_env(args.pins), {})
        for key in EDITOR_KEYS + ["CODIUM_COMMIT"]:
            versions[key] = ""
    else:
        editors = os.environ["RELEASE_EDITORS"]
        result = classify_check(editor_outcomes(os.environ))
        versions = tested_versions(updates.read_env(args.pins), updates.parse_update(editors, partial=True))
    row = {"target": args.tag, "kind": "editor-check", "commit": args.commit,
           "tested_at": now(), "result": result, **versions,
           "RUNTIME_BASH_VERSION": "", "RUNTIME_PODMAN_VERSION": "", "run_url": os.environ["RUN_URL"]}
    validate(row)
    print(json.dumps(row))


def release_row(tag, commit, pins, env):
    """A published release's own row: its pins and the gates' runtime versions."""
    row = {"target": tag, "kind": "release", "commit": commit,
           "tested_at": env["TESTED_AT"], "result": "pass", **tested_versions(pins, {}),
           "RUNTIME_BASH_VERSION": env["RUNTIME_BASH_VERSION"],
           "RUNTIME_PODMAN_VERSION": env["RUNTIME_PODMAN_VERSION"],
           "run_url": env["TEST_RUN_URL"]}
    validate(row)
    return row


def command_release_row(args):
    print(json.dumps(release_row(args.tag, args.commit, updates.read_env(args.pins), os.environ)))


def command_append(args):
    append(args.path, json.loads(sys.stdin.read()))


def command_recorded(args):
    row = json.loads(Path(args.row).read_text(encoding="utf-8"))
    print("true" if recorded(read_rows(args.history), row) else "false")


def command_release_target(args):
    releases = read_rows(args.history)
    tag = release_target(releases)
    if tag and not unsupported_release_recorded(releases, tag):
        print(tag)


def command_release_editors(args):
    newest = updates.read_env(args.newest)
    editors = {key: newest[key] for key in EDITOR_KEYS}
    if not release_check_done(read_rows(args.history), args.tag, editors):
        print(updates.format_update(updates.parse_update(updates.format_update(editors), partial=True)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    target = commands.add_parser("release-target")
    target.add_argument("history")
    target.set_defaults(handler=command_release_target)
    editors = commands.add_parser("release-editors")
    editors.add_argument("history")
    editors.add_argument("tag")
    editors.add_argument("newest")
    editors.set_defaults(handler=command_release_editors)
    check = commands.add_parser("check-row")
    for name in ("tag", "commit", "pins"):
        check.add_argument(name)
    check.set_defaults(handler=command_check_row)
    release = commands.add_parser("release-row")
    for name in ("tag", "commit", "pins"):
        release.add_argument(name)
    release.set_defaults(handler=command_release_row)
    add = commands.add_parser("append")
    add.add_argument("path")
    add.set_defaults(handler=command_append)
    seen = commands.add_parser("recorded")
    seen.add_argument("history")
    seen.add_argument("row")
    seen.set_defaults(handler=command_recorded)
    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except (ValueError, KeyError, OSError, csv.Error) as error:
        raise SystemExit(f"Error: {error}")


if __name__ == "__main__":
    main()
