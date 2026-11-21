#!/usr/bin/env bash
# Print the Go series (for example 1.27) named by the go directive in go.mod.
# Go's tools may write the directive as 1.N or 1.N.P and may add a toolchain
# line. Jailbox builds with the newest patch release of the series either way.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module=${1:-"$ROOT/src/go.mod"}

version=$(awk '$1 == "go" { print $2; exit }' "$module") || {
    printf 'Error: could not read %s\n' "$module" >&2
    exit 1
}
if [[ "$version" =~ ^(1\.(0|[1-9][0-9]*))(\.(0|[1-9][0-9]*))?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
else
    printf "Error: unsupported go directive in go.mod: '%s'\n" "$version" >&2
    exit 1
fi
