#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
series=$(bash "$ROOT/scripts/go-series.sh")
minor=${series#1.}
resolve() { GO_RELEASE_LISTING="$tmp/$1.json" bash "$ROOT/scripts/go-version.sh"; }

# The newest listed patch of the go.mod series is selected.
printf '[{"version":"go1.%s.3","stable":true},{"version":"go%s.9","stable":true}]\n' \
    "$((minor + 1))" "$series" > "$tmp/supported.json"
[[ $(resolve supported) = "$series.9" ]]

# Once both supported series are newer, resolution fails and names them.
printf '[{"version":"go1.%s.0","stable":true},{"version":"go1.%s.4","stable":true},{"version":"go%s.9","stable":false}]\n' \
    "$((minor + 2))" "$((minor + 1))" "$series" > "$tmp/unsupported.json"
if resolve unsupported 2> "$tmp/error"; then exit 1; fi
grep -Fq "Go $series is no longer supported" "$tmp/error"
grep -Fq "go1.$((minor + 2)).0, go1.$((minor + 1)).4" "$tmp/error"

# An empty or malformed listing is an error, not a pass.
printf '[]\n' > "$tmp/empty.json"
if resolve empty 2>/dev/null; then exit 1; fi
printf 'not json\n' > "$tmp/bad.json"
if resolve bad 2>/dev/null; then exit 1; fi

# A requested release must belong to the series; it needs no listing.
[[ $(GO_RELEASE_LISTING=/nonexistent bash "$ROOT/scripts/go-version.sh" "$series.12") = "$series.12" ]]
for requested in "1.$((minor + 1)).0" "$series" "$series.x" "go$series.1"; do
    if bash "$ROOT/scripts/go-version.sh" "$requested" 2>/dev/null; then exit 1; fi
done

# The series is the first two numbers of the go directive, in any form Go's
# tools write it, and a toolchain line does not change it.
check_series() {
    printf 'module example\n\n%s\n' "$1" > "$tmp/go.mod"
    [[ $(bash "$ROOT/scripts/go-series.sh" "$tmp/go.mod") = "$2" ]]
}
check_series 'go 1.27' 1.27
check_series 'go 1.27.0' 1.27
check_series $'go 1.28.3\n\ntoolchain go1.28.5' 1.28
for directive in 'go 1.28rc1' 'go 2' 'go 1.027' 'go 1.27.x'; do
    printf 'module example\n\n%s\n' "$directive" > "$tmp/go.mod"
    if bash "$ROOT/scripts/go-series.sh" "$tmp/go.mod" 2>/dev/null; then exit 1; fi
done
