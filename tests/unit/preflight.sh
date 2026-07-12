#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/preflight.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_contains() {
    local name="$1" text="$2" expected="$3"

    if grep -Fq "$expected" <<< "$text"; then
        pass "$name"
    else
        fail "$name (missing '$expected')"
    fi
}

assert_empty() {
    local name="$1" text="$2"

    if [ -z "$text" ]; then
        pass "$name"
    else
        fail "$name (got '$text')"
    fi
}

with_limit_file() {
    LIMIT_DIR=$(mktemp -d)
    JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE="$LIMIT_DIR/max_user_watches"
    export JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE
}

cleanup_limit_file() {
    rm -rf "$LIMIT_DIR"
    unset JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE
}

test_low_inotify_limit_warns_with_host_fix() {
    local output

    with_limit_file
    printf '%s\n' 65536 > "$JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE"

    output=$(warn_low_inotify_watch_limit 2>&1)

    assert_contains "low inotify limit warning mentions current value" "$output" "fs.inotify.max_user_watches is 65536"
    assert_contains "low inotify limit warning includes persistent host fix" "$output" "/etc/sysctl.d/60-jailbox-inotify.conf"
    cleanup_limit_file
}

test_recommended_inotify_limit_is_quiet() {
    local output

    with_limit_file
    printf '%s\n' 524288 > "$JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE"

    output=$(warn_low_inotify_watch_limit 2>&1)

    assert_empty "recommended inotify limit is quiet" "$output"
    cleanup_limit_file
}

main() {
    echo "preflight tests"
    echo ""

    test_low_inotify_limit_warns_with_host_fix
    test_recommended_inotify_limit_is_quiet

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "preflight tests: $PASSED passed"
    else
        echo "preflight tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
