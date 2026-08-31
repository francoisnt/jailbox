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

API_FILE="$FIXTURE/host/public-api.sh"

# The portable gate also runs on macOS, where sed is BSD sed: it requires an
# argument to -i and does not accept a one-line `a\text` append. Edit the
# fixture with awk, which behaves the same in both environments. Each edit is
# self-checking: a no-op would leave the API unchanged and fail its assertion.
insert_after_line() {
    local marker="$1" text="$2"

    awk -v marker="$marker" -v text="$text" '
        { print }
        $0 == marker { print text }
    ' "$API_FILE" > "$FIXTURE/api.tmp"
    mv "$FIXTURE/api.tmp" "$API_FILE"
}

delete_line() {
    local marker="$1"

    awk -v marker="$marker" '$0 != marker' "$API_FILE" > "$FIXTURE/api.tmp"
    mv "$FIXTURE/api.tmp" "$API_FILE"
}

assert_result "unchanged public API detected" unchanged
insert_after_line 'CONFIG_SCALAR_KEYS=(' '    TEST_CONFIG'
assert_result "added configuration detected" added
git -C "$FIXTURE" checkout -q -- host/public-api.sh
insert_after_line 'CLI_FLAGS_WITHOUT_VALUES=(' '    test-command'
assert_result "added CLI declaration detected" added
git -C "$FIXTURE" checkout -q -- host/public-api.sh
delete_line '    DEV_IMAGE'
assert_result "removed configuration detected" removed
git -C "$FIXTURE" checkout -q -- host/public-api.sh
delete_line '    doctor'
assert_result "removed CLI declaration detected" removed

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "public API diff tests: $PASSED passed"
else
    echo "public API diff tests: $PASSED passed, $FAILED failed"
    exit 1
fi
