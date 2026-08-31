#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

mkdir -p "$FIXTURE/host" "$FIXTURE/scripts"
cp "$JAILBOX_DIR/host/public-api.sh" "$FIXTURE/host/public-api.sh"
cp "$JAILBOX_DIR/scripts/public-api-diff.sh" "$FIXTURE/scripts/public-api-diff.sh"
git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" config user.email test@example.invalid
git -C "$FIXTURE" add host/public-api.sh scripts/public-api-diff.sh
git -C "$FIXTURE" commit -qm baseline

assert_result() {
    local name="$1" expected="$2" actual
    actual=$("$FIXTURE/scripts/public-api-diff.sh" HEAD)
    if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name (expected $expected, got $actual)"; fi
}

assert_result "unchanged public API detected" unchanged
sed -i '/CONFIG_SCALAR_KEYS=(/a\    TEST_CONFIG' "$FIXTURE/host/public-api.sh"
assert_result "added configuration detected" added
git -C "$FIXTURE" checkout -q -- host/public-api.sh
sed -i '/CLI_FLAGS_WITHOUT_VALUES=(/a\    test-command' "$FIXTURE/host/public-api.sh"
assert_result "added CLI declaration detected" added
git -C "$FIXTURE" checkout -q -- host/public-api.sh
sed -i '/    DEV_IMAGE/d' "$FIXTURE/host/public-api.sh"
assert_result "removed configuration detected" removed
git -C "$FIXTURE" checkout -q -- host/public-api.sh
sed -i '/    doctor/d' "$FIXTURE/host/public-api.sh"
assert_result "removed CLI declaration detected" removed

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "public API diff tests: $PASSED passed"
else
    echo "public API diff tests: $PASSED passed, $FAILED failed"
    exit 1
fi
