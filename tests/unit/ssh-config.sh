#!/bin/bash
# Unit tests for generated SSH config snippets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=host/ssh.sh
source "$JAILBOX_DIR/host/ssh.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_contains() {
    local name="$1" text="$2" expected="$3"

    if grep -Fq "$expected" <<< "$text"; then
        pass "$name"
    else
        fail "$name (missing: $expected)"
    fi
}

test_paths_with_spaces_are_quoted() {
    local output

    CONTAINER_NAME="jailbox-test"
    LOCAL_PORT="50222"
    MANAGED_USER="jailbox"
    KEY_FILE="/tmp/jailbox path/state/key"
    KNOWN_HOSTS="/tmp/jailbox path/state/known_hosts"
    SSH_SESSION_ENV=()

    output=$(write_ssh_host_block)

    assert_contains "IdentityFile path is quoted" "$output" \
        '    IdentityFile "/tmp/jailbox path/state/key"'
    assert_contains "UserKnownHostsFile path is quoted" "$output" \
        '    UserKnownHostsFile "/tmp/jailbox path/state/known_hosts"'
    assert_contains "StrictHostKeyChecking is enabled" "$output" \
        '    StrictHostKeyChecking yes'
}

test_quotes_inside_paths_are_escaped() {
    local output

    CONTAINER_NAME="jailbox-test"
    LOCAL_PORT="50222"
    MANAGED_USER="jailbox"
    KEY_FILE='/tmp/jailbox "quoted"/state/key'
    KNOWN_HOSTS='/tmp/jailbox "quoted"/state/known_hosts'
    SSH_SESSION_ENV=()

    output=$(write_ssh_host_block)

    assert_contains "IdentityFile embedded quote is escaped" "$output" \
        '    IdentityFile "/tmp/jailbox \"quoted\"/state/key"'
    assert_contains "UserKnownHostsFile embedded quote is escaped" "$output" \
        '    UserKnownHostsFile "/tmp/jailbox \"quoted\"/state/known_hosts"'
}

test_known_host_entry_is_pinned() {
    local dir expected

    dir=$(mktemp -d)
    KNOWN_HOSTS="$dir/known_hosts"
    LOCAL_PORT="50222"
    expected="[localhost]:50222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey"

    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStaleKey\n' "[localhost]:50222" > "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    write_known_host_entry "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey"

    if grep -Fxq "$expected" "$KNOWN_HOSTS"; then
        pass "known_hosts contains pinned localhost port key"
    else
        fail "known_hosts contains pinned localhost port key"
    fi
    if grep -Fq "IStaleKey" "$KNOWN_HOSTS"; then
        fail "known_hosts removes stale localhost port key"
    else
        pass "known_hosts removes stale localhost port key"
    fi
    rm -rf "$dir"
}

main() {
    echo "ssh config tests"
    echo ""

    test_paths_with_spaces_are_quoted
    test_quotes_inside_paths_are_escaped
    test_known_host_entry_is_pinned

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "ssh config tests: $PASSED passed"
    else
        echo "ssh config tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
