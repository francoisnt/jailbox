#!/usr/bin/env bash
# Print the exact Go release CI and releases use: the newest patch release of
# the series in src/go.mod. Fail once go.dev no longer supports that series.
# With VERSION, check that it belongs to the series and print it instead.
# GO_RELEASE_LISTING names a saved go.dev listing for tests.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

series=$(bash "$ROOT/scripts/go-series.sh") || exit 1
if [[ $# -gt 0 ]]; then
    [[ $# -eq 1 && "$1" =~ ^${series//./\\.}\.(0|[1-9][0-9]*)$ ]] ||
        die "Go version '$*' is not a release of the Go $series series"
    printf '%s\n' "$1"
    exit 0
fi
if [[ -n "${GO_RELEASE_LISTING:-}" ]]; then
    listing=$(cat -- "$GO_RELEASE_LISTING") || die "could not read $GO_RELEASE_LISTING"
else
    listing=$(curl -fsSL --retry 3 'https://go.dev/dl/?mode=json') || die 'could not fetch supported Go releases'
fi
# go.dev lists only supported stable releases, newest first within a series.
supported=$(python3 -c 'import json, sys
print("\n".join(r["version"] for r in json.load(sys.stdin) if r["stable"]))' <<< "$listing") ||
    die 'could not parse supported Go releases'
[[ -n "$supported" ]] || die 'go.dev listed no supported Go releases'

while IFS= read -r version; do
    if [[ "$version" =~ ^go(${series//./\\.}\.(0|[1-9][0-9]*))$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        exit 0
    fi
done <<< "$supported"
die "Go $series is no longer supported; update src/go.mod and the root Containerfile (supported: ${supported//$'\n'/, })"
