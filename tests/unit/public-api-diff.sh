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
insert_after_line 'CLI_OTHER_COMMANDS=(' '    test-command'
assert_result "added CLI declaration detected" added
git -C "$FIXTURE" checkout -q -- host/public-api.sh
delete_line '    DEV_IMAGE'
assert_result "removed configuration detected" removed
git -C "$FIXTURE" checkout -q -- host/public-api.sh
delete_line '    status'
assert_result "removed CLI declaration detected" removed
git -C "$FIXTURE" checkout -q -- host/public-api.sh
delete_line '    EDITOR'
assert_result "removed frontend declaration detected" removed
git -C "$FIXTURE" checkout -q -- host/public-api.sh
insert_after_line 'FRONTEND_SCALAR_KEYS=(' '    TEST_FRONTEND'
assert_result "added frontend declaration detected" added

# Required producer failures may emit plausible output before failing. Fail an
# early extraction only, so later successful reads cannot mask it.
mkdir "$FIXTURE/bin"
for tool in sort awk sed cat comm git; do
    real_tool=$(command -v "$tool")
    for partial in '' ORIGINAL; do
        cat > "$FIXTURE/bin/$tool" <<'STUB'
#!/bin/bash
if [ ! -e "$FAULT_MARKER" ]; then
    : > "$FAULT_MARKER"
    printf '%s' "$FAULT_OUTPUT"
    exit 42
fi
exec "$REAL_TOOL" "$@"
STUB
        chmod 755 "$FIXTURE/bin/$tool"
        rm -f "$FIXTURE/fired"
        if output=$(PATH="$FIXTURE/bin:$PATH" REAL_TOOL="$real_tool" FAULT_MARKER="$FIXTURE/fired" FAULT_OUTPUT="$partial" "$FIXTURE/scripts/public-api-diff.sh" HEAD); then
            fail "$tool failure was accepted"
        elif [ -n "$output" ]; then
            fail "$tool failure emitted classification: $output"
        else
            pass "$tool failure with '$partial' output refuses classification"
        fi
    done
    rm "$FIXTURE/bin/$tool"
done

# A readable tree listing does not establish that reading its blob succeeded.
real_git=$(command -v git)
cat > "$FIXTURE/bin/git" <<'STUB'
#!/bin/bash
if [[ "${3:-}" == show ]]; then printf '%s' "$FAULT_OUTPUT"; exit 42; fi
exec "$REAL_GIT" "$@"
STUB
chmod 755 "$FIXTURE/bin/git"
for partial in '' 'CONFIG_SCALAR_KEYS=('; do
    if output=$(PATH="$FIXTURE/bin:$PATH" REAL_GIT="$real_git" FAULT_OUTPUT="$partial" "$FIXTURE/scripts/public-api-diff.sh" HEAD); then exit 1; fi
    [[ -z "$output" ]]
done
rm "$FIXTURE/bin/git"
pass 'failed historical blob reads refuse classification'

# Historical locations and combined/split declarations remain readable, with
# genuinely absent arrays contributing no names.
mkdir "$FIXTURE/lib"
for declaration in CLI_FLAGS CLI_FLAGS_WITHOUT_VALUES; do
    printf 'CONFIG_SCALAR_KEYS=(\n    ORIGINAL\n)\n%s=(\n    --help\n)\n' "$declaration" > "$API_FILE"
    cp "$API_FILE" "$FIXTURE/lib/public-api.sh"
    git -C "$FIXTURE" rm -fq host/public-api.sh
    git -C "$FIXTURE" add lib/public-api.sh
    git -C "$FIXTURE" commit -qm historical
    mkdir -p "$FIXTURE/host"
    cp "$FIXTURE/lib/public-api.sh" "$API_FILE"
    assert_result "historical $declaration in lib" unchanged
    git -C "$FIXTURE" add host/public-api.sh
    git -C "$FIXTURE" commit -qm current-location
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "public API diff tests: $PASSED passed"
else
    echo "public API diff tests: $PASSED passed, $FAILED failed"
    exit 1
fi
