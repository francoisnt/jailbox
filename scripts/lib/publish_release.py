#!/usr/bin/env python3
"""Prepare a GitHub draft and publish it by ID once its assets are complete."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from compatibility_history import SHA, TAG

PLATFORMS = ("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64")


def gh_api(endpoint, *args, payload=None):
    command = ["gh", "api", endpoint, *args]
    if payload is not None:
        command += ["--input", "-", "-H", "Content-Type: application/json"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else "",
                            stdout=subprocess.PIPE, text=True, check=True)
    return json.loads(result.stdout) if result.stdout else None


def list_entries(endpoint):
    return (entry for page in gh_api(endpoint, "--paginate", "--slurp") for entry in page)


def release_assets(version, directory):
    names = {f"jailbox-{label}-{platform}.tar.gz"
             for platform in PLATFORMS for label in (version, "latest")} | {"install.sh"}
    checksums = directory / "SHA256SUMS"
    entries = checksums.read_text(encoding="ascii").splitlines()
    if len(entries) != len(names):
        raise ValueError("unexpected number of release checksums")
    assets = [checksums]
    for line in entries:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] not in names:
            raise ValueError("unexpected release checksum entry")
        digest, name = match.groups()
        names.remove(name)
        asset = directory / name
        if hashlib.sha256(asset.read_bytes()).hexdigest() != digest:
            raise ValueError(f"checksum mismatch for {name}")
        assets.append(asset)
    return sorted(assets)


def require_absent_tag(repo, version):
    matches = gh_api(f"{repo}/git/matching-refs/tags/{version}")
    if any(ref["ref"] == f"refs/tags/{version}" for ref in matches):
        raise ValueError(f"version tag already exists for {version}")


def publish(repo, version, commit, notes, assets):
    endpoint = f"{repo}/releases"
    require_absent_tag(repo, version)
    previous = [entry for entry in list_entries(endpoint) if entry["tag_name"] == version]
    if any(not entry["draft"] for entry in previous):
        raise ValueError(f"release {version} is already published")
    # Replace incomplete drafts so stale notes and assets cannot survive a retry.
    for entry in previous:
        gh_api(f"{endpoint}/{int(entry['id'])}", "--method", "DELETE")

    details = {"tag_name": version, "target_commitish": commit, "name": version, "body": notes}
    draft = gh_api(endpoint, "--method", "POST", payload={**details, "draft": True})
    draft_id = int(draft["id"])
    release = f"{endpoint}/{draft_id}"
    upload = f"https://uploads.github.com/{release}/assets"
    if not draft["draft"] or draft["upload_url"] != upload + "{?name,label}":
        raise ValueError(f"invalid response while preparing draft {draft_id}")
    print(f"Prepared draft {draft_id} for {version} at {commit}", flush=True)

    for asset in assets:
        gh_api(f"{upload}?name={asset.name}", "--method", "POST", "--input", str(asset),
               "-H", "Content-Type: application/octet-stream")
    uploaded = list(list_entries(f"{release}/assets"))
    expected = {asset.name: ("uploaded", asset.stat().st_size) for asset in assets}
    observed = {item["name"]: (item["state"], item["size"]) for item in uploaded}
    if len(uploaded) != len(expected) or observed != expected:
        raise ValueError(f"draft {draft_id} does not have all expected assets")

    require_absent_tag(repo, version)
    published = gh_api(release, "--method", "PATCH", payload={**details, "draft": False})
    if published["draft"] or published["id"] != draft_id or published["tag_name"] != version:
        raise ValueError(f"GitHub did not publish draft {draft_id}")
    tag = gh_api(f"{repo}/git/ref/tags/{version}")
    if tag["object"]["type"] != "commit" or tag["object"]["sha"] != commit:
        raise ValueError(f"GitHub did not create {version} at the tested commit")
    print(f"Published {version} at {commit}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("commit")
    parser.add_argument("notes", type=Path)
    parser.add_argument("dist", type=Path)
    args = parser.parse_args()
    if not TAG.fullmatch(args.version) or not SHA.fullmatch(args.commit):
        parser.error("expected a release version and full Git commit ID")
    try:
        notes = args.notes.read_text(encoding="utf-8")
        if not notes.strip():
            raise ValueError("release notes are empty")
        assets = release_assets(args.version, args.dist)
        publish(f"repos/{os.environ['GITHUB_REPOSITORY']}", args.version, args.commit, notes, assets)
    except (KeyError, OSError, subprocess.CalledProcessError, ValueError) as error:
        raise SystemExit(f"Error publishing release: {error}")


if __name__ == "__main__":
    main()
