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
# It exits 3, which callers tell apart from a failed lookup (exit 1).
status=0
resolve unsupported 2> "$tmp/error" || status=$?
[[ $status -eq 3 ]]
grep -Fq "Go $series is no longer supported" "$tmp/error"
grep -Fq "go1.$((minor + 2)).0, go1.$((minor + 1)).4" "$tmp/error"

# An empty, malformed, or missing listing is an error, not a pass.
printf '[]\n' > "$tmp/empty.json"
printf 'not json\n' > "$tmp/bad.json"
for listing in empty bad missing; do
    status=0
    resolve "$listing" 2>/dev/null || status=$?
    [[ $status -eq 1 ]]
done

# The newest supported series is the highest numbered stable one.
[[ $(GO_RELEASE_LISTING="$tmp/unsupported.json" bash "$ROOT/scripts/go-version.sh" --newest-series) = "1.$((minor + 2))" ]]
printf '[{"version":"go1.9.1","stable":true},{"version":"go1.10.0","stable":true}]\n' > "$tmp/order.json"
[[ $(GO_RELEASE_LISTING="$tmp/order.json" bash "$ROOT/scripts/go-version.sh" --newest-series) = 1.10 ]]
if GO_RELEASE_LISTING="$tmp/empty.json" bash "$ROOT/scripts/go-version.sh" --newest-series 2>/dev/null; then exit 1; fi

# --go-mod reads the series from another go.mod, such as a release tag's copy.
printf 'module example\n\ngo 1.%s.0\n' "$((minor + 1))" > "$tmp/newer.mod"
[[ $(GO_RELEASE_LISTING="$tmp/supported.json" bash "$ROOT/scripts/go-version.sh" --go-mod "$tmp/newer.mod") == \
    "1.$((minor + 1)).3" ]]
[[ $(GO_RELEASE_LISTING=/nonexistent bash "$ROOT/scripts/go-version.sh" --go-mod "$tmp/newer.mod" "1.$((minor + 1)).7") == \
    "1.$((minor + 1)).7" ]]
printf 'module example\n\ngo 1.%s\n' "$((minor + 3))" > "$tmp/unlisted.mod"
status=0
GO_RELEASE_LISTING="$tmp/supported.json" bash "$ROOT/scripts/go-version.sh" --go-mod "$tmp/unlisted.mod" \
    2> "$tmp/error" || status=$?
[[ $status -eq 3 ]]
grep -Fq "update $tmp/unlisted.mod" "$tmp/error"
if bash "$ROOT/scripts/go-version.sh" --go-mod 2>/dev/null; then exit 1; fi

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
