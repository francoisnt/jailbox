#!/usr/bin/env bash
# Download a public GitHub Actions artifact through nightly.link, without a token.
# Find IDs with GET https://api.github.com/repos/OWNER/REPO/actions/runs/RUN_ID/artifacts
# Requires curl and Python 3. Downloads a ZIP; does not extract or execute it.
set -euo pipefail

if (($# != 3)); then
    echo 'Usage: scripts/download-ci-artifact.sh OWNER/REPO ARTIFACT_ID OUTPUT.zip' >&2
    exit 2
fi
repo=$1
artifact_id=$2
output=$3
if [[ ! $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || ! $artifact_id =~ ^[1-9][0-9]*$ ]]; then
    echo 'Error: expected OWNER/REPO and a positive numeric artifact ID.' >&2
    exit 2
fi
for dependency in curl python3; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'Error: required command missing: %s\n' "$dependency" >&2
        exit 1
    }
done

# Prepare beside the destination so publication is a single rename. Failed
# downloads leave any previous destination intact and remove the partial ZIP.
temporary=$(mktemp "${output}.XXXXXX") || exit 1
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 --retry 2 \
    "https://nightly.link/$repo/actions/artifacts/$artifact_id.zip" \
    --output "$temporary" || exit 1
python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); sys.exit(1 if z.testzip() else 0)' \
    "$temporary" || { echo 'Error: downloaded artifact is not a valid ZIP.' >&2; exit 1; }
mv -f -- "$temporary" "$output" || exit 1
printf 'Downloaded artifact %s from %s.\n' "$artifact_id" "$repo"
