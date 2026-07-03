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

main() {
    echo "ssh config tests"
    echo ""

    test_paths_with_spaces_are_quoted
    test_quotes_inside_paths_are_escaped

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "ssh config tests: $PASSED passed"
    else
        echo "ssh config tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
