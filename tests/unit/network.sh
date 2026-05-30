#!/bin/bash
# Unit tests for host/network.sh helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Safe because host/network.sh currently contains only function definitions and
# no top-level executable code. Keep that true for this unit test; accidentally
# calling configure_network or related functions here would invoke podman, which
# is intentionally unavailable in the unit-test environment.
# shellcheck source=host/network.sh
source "$JAILBOX_DIR/host/network.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_contains_line() {
    local name="$1" file="$2" expected="$3"
    if grep -Fxq "$expected" "$file"; then
        pass "$name"
    else
        fail "$name (missing line: $expected)"
    fi
}

assert_no_match() {
    local name="$1" file="$2" candidate="$3"
    if grep -Eq -f "$file" <<< "$candidate"; then
        fail "$name ($candidate matched unexpectedly)"
    else
        pass "$name"
    fi
}

test_tinyproxy_exact_match_patterns() {
    local d filter escaped

    d=$(mktemp -d)
    filter="$d/filter"
    escaped="$(tinyproxy_escape_host "example.com")"
    printf '^%s$\n' "$escaped" >> "$filter"
    printf '\\.%s$\n' "$escaped" >> "$filter"

    assert_contains_line "tinyproxy: exact domain pattern" "$filter" '^example\.com$'
    assert_contains_line "tinyproxy: subdomain pattern" "$filter" '\.example\.com$'
    assert_no_match "tinyproxy: no xexample.com overmatch" "$filter" "xexample.com"

    rm -rf "$d"
}

main() {
    echo "network tests"
    echo ""

    test_tinyproxy_exact_match_patterns

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "network tests: $PASSED passed"
    else
        echo "network tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
