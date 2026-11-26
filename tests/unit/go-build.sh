#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tree/scripts" "$tmp/tree/src" "$tmp/bin"
cp "$ROOT/scripts/build-programs.sh" "$ROOT/scripts/go-series.sh" "$tmp/tree/scripts/"
cp "$ROOT/src/go.mod" "$tmp/tree/src/"
cp "$ROOT/tests/fixtures/go-build-command.sh" "$tmp/bin/go"
chmod 755 "$tmp/bin/go"
export PATH="$tmp/bin:$PATH" GO_BUILD_TRACE="$tmp/trace" GO_BUILD_MARKER=initial
GO_BUILD_SERIES=$(bash "$ROOT/scripts/go-series.sh")
export GO_BUILD_SERIES
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) native=linux-amd64 ;;
    Linux/aarch64|Linux/arm64) native=linux-arm64 ;;
    Darwin/x86_64) native=darwin-amd64 ;;
    Darwin/arm64) native=darwin-arm64 ;;
    *) exit 1 ;;
esac

build="$tmp/tree/scripts/build-programs.sh"
output="$tmp/tree/src/libexec"
expected_builds() {
    local target
    printf '%s ./container/cmd/jailbox-container\n' linux-amd64 linux-arm64
    for target in "$@"; do
        printf '%s ./host/core/cmd/jailbox-core\n' "$target"
    done
    if [[ "$native" = darwin-* ]]; then
        printf '%s ./container/cmd/jailbox-container\n' "$native"
    fi
}
assert_checkout_layout() {
    [[ $(cat "$output/jailbox-core") = "$native ./host/core/cmd/jailbox-core initial" ]]
    [[ $(cat "$output/native/jailbox-container") = "$native ./container/cmd/jailbox-container initial" ]]
    [[ -x "$output/linux-amd64/jailbox-container" && -x "$output/linux-arm64/jailbox-container" ]]
    [[ ! -e "$output/core" ]]
    if compgen -G "$output/.build.*" >/dev/null; then return 1; fi
}

# Ordinary checkout builds still build only their native core target.
bash "$build"
expected_builds "$native" > "$tmp/expected"
cmp "$tmp/trace" "$tmp/expected"
assert_checkout_layout

# Development checks build every supported core exactly once, publishing
# only the normal checkout binaries.
: > "$GO_BUILD_TRACE"
bash "$build" --check-platforms
expected_builds linux-amd64 linux-arm64 darwin-amd64 darwin-arm64 > "$tmp/expected"
cmp "$tmp/trace" "$tmp/expected"
assert_checkout_layout

# A failure on a non-native core must not replace any existing binary.
cp -R "$output" "$tmp/before"
failure=darwin-amd64
[[ "$native" != "$failure" ]] || failure=linux-amd64
if GO_BUILD_FAIL_TARGET="$failure" GO_BUILD_MARKER=changed bash "$build" --check-platforms; then
    exit 1
fi
diff -r "$tmp/before" "$output"
