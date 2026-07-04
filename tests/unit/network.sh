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
    local d filter

    d=$(mktemp -d)
    filter="$d/filter"
    render_tinyproxy_filter "$filter" "example.com"

    assert_contains_line "tinyproxy: exact domain pattern" "$filter" '^example\.com$'
    assert_contains_line "tinyproxy: subdomain pattern" "$filter" '\.example\.com$'
    assert_no_match "tinyproxy: no xexample.com overmatch" "$filter" "xexample.com"

    rm -rf "$d"
}

test_tinyproxy_filter_rerender() {
    local d filter

    d=$(mktemp -d)
    filter="$d/filter"
    printf 'stale\n' > "$filter"

    render_tinyproxy_filter "$filter" "github.com" "api.github.com"

    assert_contains_line "tinyproxy: rerender exact domain" "$filter" '^github\.com$'
    assert_contains_line "tinyproxy: rerender second domain" "$filter" '^api\.github\.com$'
    if grep -Fxq "stale" "$filter"; then
        fail "tinyproxy: rerender removes stale lines"
    else
        pass "tinyproxy: rerender removes stale lines"
    fi

    rm -rf "$d"
}

test_proxy_internal_address() {
    PROJECT_HASH="abcdef123456"

    case "$(proxy_internal_subnet)" in
        10.240.*.0/24)
            pass "proxy internal subnet is private /24"
            ;;
        *)
            fail "proxy internal subnet is private /24 (got $(proxy_internal_subnet))"
            ;;
    esac

    case "$(proxy_internal_ip)" in
        10.240.*.2)
            pass "proxy internal IP is inside subnet"
            ;;
        *)
            fail "proxy internal IP is inside subnet (got $(proxy_internal_ip))"
            ;;
    esac
}

test_proxy_subnet_candidates_distinct() {
    PROJECT_HASH="abcdef123456"

    if [ "$(proxy_internal_subnet 0)" != "$(proxy_internal_subnet 1)" ]; then
        pass "collision fallback candidates use distinct subnets"
    else
        fail "collision fallback candidates use distinct subnets (both $(proxy_internal_subnet 0))"
    fi
}

test_proxy_ip_for_subnet() {
    if [ "$(proxy_ip_for_subnet "10.240.57.0/24")" = "10.240.57.2" ]; then
        pass "proxy IP derived from subnet"
    else
        fail "proxy IP derived from subnet (got $(proxy_ip_for_subnet "10.240.57.0/24"))"
    fi
}

test_render_tinyproxy_conf() {
    local d conf

    d=$(mktemp -d)
    conf="$d/tinyproxy.conf"
    SCRIPT_DIR="$JAILBOX_DIR"
    render_tinyproxy_conf "$conf" "10.240.57.0/24"

    assert_contains_line "tinyproxy conf: client ACL rendered" "$conf" "Allow 10.240.57.0/24"
    assert_contains_line "tinyproxy conf: base config included" "$conf" "FilterDefaultDeny Yes"
    local conf_mode
    conf_mode=$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf")
    if [ "$conf_mode" = "644" ]; then
        pass "tinyproxy conf: readable by unprivileged proxy user"
    else
        fail "tinyproxy conf: readable by unprivileged proxy user (mode $conf_mode)"
    fi

    rm -rf "$d"
}

test_configure_proxy_env_preserves_precomputed_url() {
    NETWORK_NAME="jailbox-unittest-net"
    PROXY_NAME="proxy-name"
    PROXY_URL="http://10.240.5.2:8888"

    configure_proxy_env

    if [ "$PROXY_URL" = "http://10.240.5.2:8888" ]; then
        pass "proxy env keeps static proxy URL"
    else
        fail "proxy env keeps static proxy URL (got $PROXY_URL)"
    fi
    if [ "${SSH_SESSION_ENV[0]}" = "HTTP_PROXY=http://10.240.5.2:8888" ]; then
        pass "SSH session env uses static proxy URL"
    else
        fail "SSH session env uses static proxy URL (got ${SSH_SESSION_ENV[0]})"
    fi
}

test_configure_proxy_env_computes_static_url() {
    PROJECT_HASH="abcdef123456"
    NETWORK_NAME="jailbox-unittest-net"
    PROXY_NAME="proxy-name"
    PROXY_URL=""
    EGRESS_ALLOW=(api.example.test)

    configure_proxy_env

    if [[ "$PROXY_URL" =~ ^http://10\.240\.[0-9]+\.2:8888$ ]]; then
        pass "proxy env computes static proxy URL in egress mode"
    else
        fail "proxy env computes static proxy URL in egress mode (got $PROXY_URL)"
    fi
}

main() {
    echo "network tests"
    echo ""

    test_tinyproxy_exact_match_patterns
    test_tinyproxy_filter_rerender
    test_proxy_internal_address
    test_proxy_subnet_candidates_distinct
    test_proxy_ip_for_subnet
    test_render_tinyproxy_conf
    test_configure_proxy_env_preserves_precomputed_url
    test_configure_proxy_env_computes_static_url

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "network tests: $PASSED passed"
    else
        echo "network tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
