#!/usr/bin/env bash
# Print the exact Go release CI and releases use: the newest patch release of
# the series in src/go.mod. Exit 3 once go.dev no longer supports that series,
# and 1 when the supported releases cannot be read.
#
# Usage: scripts/go-version.sh [--go-mod FILE] [VERSION | --newest-series]
#   --go-mod FILE    read the series from FILE instead of src/go.mod
#   VERSION          check that it belongs to the series and print it instead
#   --newest-series  print the newest supported stable series
# GO_RELEASE_LISTING names a saved go.dev listing for tests.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

module=$ROOT/src/go.mod
if [[ ${1-} == --go-mod ]]; then
    [[ $# -ge 2 ]] || die 'expected a file after --go-mod'
    module=$2
    shift 2
fi
series=$(bash "$ROOT/scripts/go-series.sh" "$module") || exit 1
[[ $# -le 1 ]] || die 'expected at most one argument'
mode=${1:-}
if [[ $# -gt 0 && "$mode" != --newest-series ]]; then
    [[ "$mode" =~ ^${series//./\\.}\.(0|[1-9][0-9]*)$ ]] ||
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
numbered=$(sed -nE 's/^go(1\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$/\1/p' <<< "$supported") || exit 1
[[ -n "$numbered" ]] || die 'go.dev listed no numbered Go release'

if [[ "$mode" == --newest-series ]]; then
    cut -d. -f1,2 <<< "$numbered" | sort -t. -k2,2n | tail -n 1
    exit 0
fi

while IFS= read -r version; do
    if [[ "$version" == "$series".* ]]; then
        printf '%s\n' "$version"
        exit 0
    fi
done <<< "$numbered"

printf 'Error: Go %s is no longer supported; update %s (supported: %s)\n' \
    "$series" "${module#"$ROOT"/}" "${supported//$'\n'/, }" >&2
exit 3
