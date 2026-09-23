#!/bin/bash
# Unit tests for host/core/resources/network.sh helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/lib/core.sh
source "$JAILBOX_DIR/tests/lib/core.sh" "$JAILBOX_DIR/src"

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
    SCRIPT_DIR="$JAILBOX_DIR/src"
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
    NETWORK_STATE[proxy_url]="http://10.240.5.2:8888"

    configure_proxy_env

    if [ "${NETWORK_STATE[proxy_url]}" = "http://10.240.5.2:8888" ]; then
        pass "proxy env keeps static proxy URL"
    else
        fail "proxy env keeps static proxy URL (got ${NETWORK_STATE[proxy_url]})"
    fi
    if [ "${NETWORK_SSH_SESSION_ENV[0]}" = "HTTP_PROXY=http://10.240.5.2:8888" ]; then
        pass "SSH session env uses static proxy URL"
    else
        fail "SSH session env uses static proxy URL (got ${NETWORK_SSH_SESSION_ENV[0]})"
    fi
}

test_configure_proxy_env_computes_static_url() {
    PROJECT_HASH="abcdef123456"
    NETWORK_NAME="jailbox-unittest-net"
    PROXY_NAME="proxy-name"
    NETWORK_STATE[proxy_url]=""
    EGRESS_ALLOW=(api.example.test)

    configure_proxy_env

    if [[ "${NETWORK_STATE[proxy_url]}" =~ ^http://10\.240\.[0-9]+\.2:8888$ ]]; then
        pass "proxy env computes static proxy URL in egress mode"
    else
        fail "proxy env computes static proxy URL in egress mode (got ${NETWORK_STATE[proxy_url]})"
    fi
}

test_configure_proxy_env_rejects_missing_address() {
    local output
    # shellcheck disable=SC2030 # Failed derivation and its state stay isolated.
    if output=$( (
        NETWORK_STATE[proxy_url]=""
        EGRESS_ALLOW=(example.com)
        NETWORK_NAME=jailbox-unittest-net
        PROXY_NAME=jailbox-unittest-proxy
        internal_network_subnet() { return 1; }
        proxy_internal_ip() { return 1; }
        die() { printf '%s\n' "$*" >&2; exit 1; }
        configure_proxy_env
        printf 'unexpected success\n'
    ) 2>&1); then
        fail 'proxy env refuses unavailable live and derived addresses'
    elif [[ "$output" = 'could not determine an internal proxy IPv4 URL' ]]; then
        pass 'proxy env refuses unavailable addresses without a hostname fallback'
    else
        fail "proxy env reports missing IPv4 URL (got $output)"
    fi
}

test_effective_egress_allowlist_array_output() {
    local actual

    EGRESS_ALLOW=(github.com github.com api.github.com)
    EDITOR_BIN=""
    actual=(stale)
    effective_egress_allowlist actual

    if [[ "${actual[*]}" == "api.github.com github.com" ]]; then
        pass "effective allowlist sorts hosts and removes duplicates"
    else
        fail "effective allowlist sorts hosts and removes duplicates (got ${actual[*]})"
    fi

    EDITOR_BIN="/usr/bin/codium"
    effective_egress_allowlist actual
    if [[ "${actual[*]}" == "api.github.com github.com" ]]; then
        pass "core ignores editor selection"
    else
        fail "core ignores editor selection (got ${actual[*]})"
    fi

    EDITOR_BIN=""
    effective_egress_allowlist actual
    if [[ "${actual[*]}" == "api.github.com github.com" ]]; then
        pass "up-style launch omits editor bootstrap hosts"
    else
        fail "up-style launch omits editor bootstrap hosts (got ${actual[*]})"
    fi

    EGRESS_ALLOW=()
    actual=(stale)
    effective_egress_allowlist actual
    if [[ "${#actual[@]}" -eq 0 ]]; then
        pass "effective allowlist clears stale array output"
    else
        fail "effective allowlist clears stale array output"
    fi
}

# Exercise the real file comparison and metadata checks with only engine
# inspection stubbed. Equivalent policy must not rewrite the live files.
test_proxy_policy_equivalence() (
    local fixture editor expected before actual=()
    fixture=$(mktemp -d)
    trap 'rm -rf "$fixture"' EXIT
    SCRIPT_DIR=$JAILBOX_DIR/src
    # shellcheck disable=SC2030 # This fixture owns isolated network state.
    NETWORK_NAME=test-net PROXY_NAME=test-proxy LAUNCH_CONVERGING=false
    NETWORK_STATE[filter_file]=$fixture/filter
    NETWORK_STATE[proxy_conf_file]=$fixture/conf
    die() { printf '%s\n' "$*" >&2; exit 1; }
    sandbox_stop_guidance() { printf "Run 'jailbox stop' and then 'jailbox up'.\n"; }
    podman() {
        [[ "$1 $2 $3" = 'network inspect test-net-internal' ]] || return 125
        printf '10.240.57.0/24\n'
    }
    require_container_mount() { printf 'mount\n' >> "$fixture/checks"; }
    require_container_property() { printf 'property\n' >> "$fixture/checks"; }
    render_tinyproxy_conf "${NETWORK_STATE[proxy_conf_file]}" 10.240.57.0/24

    for editor in '' /usr/bin/codium /usr/bin/code; do
        EDITOR_BIN=$editor
        # shellcheck disable=SC2030 # Isolated policy fixture.
        EGRESS_ALLOW=(z.example.com a.example.com)
        effective_egress_allowlist actual
        case "$editor" in
            '') expected='a.example.com z.example.com' ;;
            */codium) expected='a.example.com z.example.com' ;;
            */code) expected='a.example.com z.example.com' ;;
        esac
        [[ "${actual[*]}" = "$expected" ]]
        render_tinyproxy_filter "${NETWORK_STATE[filter_file]}" "${actual[@]}"
        cp "${NETWORK_STATE[filter_file]}" "$fixture/original"
        EGRESS_ALLOW=(a.example.com z.example.com a.example.com)
        effective_egress_allowlist actual
        render_tinyproxy_filter "$fixture/reordered" "${actual[@]}"
        cmp "$fixture/original" "$fixture/reordered"
        : > "$fixture/checks"
        if ! validate_proxy_configuration; then exit 1; fi
        [[ $(wc -l < "$fixture/checks") -eq 4 ]]
        cmp "$fixture/original" "${NETWORK_STATE[filter_file]}"

        EGRESS_ALLOW+=(changed.example.com)
        if (validate_proxy_configuration) > "$fixture/error" 2>&1; then exit 1; fi
        grep -Fq 'proxy configuration differs from requested policy' "$fixture/error"
        grep -Fq "'jailbox stop' and then 'jailbox up'" "$fixture/error"
        cmp "$fixture/original" "${NETWORK_STATE[filter_file]}"
    done

    # A producer emitting plausible partial data must still abort comparison
    # and network setup, including under conditional invocation.
    # shellcheck disable=SC2329 # Fault injected into the sourced producer.
    sort() { printf 'a.example.com\n'; return 42; }
    actual=(stale)
    if effective_egress_allowlist actual; then exit 1; fi
    [[ -z "${actual[*]-}" ]]
    before=$(cat "$fixture/checks")
    if validate_proxy_configuration; then exit 1; fi
    [[ $(cat "$fixture/checks") = "$before" ]]
    assert_config_digest_ready() { :; }
    podman() { printf 'unexpected engine call\n' >> "$fixture/engine"; return 125; }
    if configure_network; then exit 1; fi
    [[ ! -e "$fixture/engine" ]]
    unset -f sort

    # Editor selection cannot turn an empty policy into filtered networking.
    EGRESS_ALLOW=()
    OBSERVED_RESOURCES=(network:test-net)
    # shellcheck disable=SC2034 # Deliberately irrelevant inherited editor state.
    for EDITOR_BIN in '' /usr/bin/codium /usr/bin/code; do
        actual=(stale)
        effective_egress_allowlist actual
        [[ -z "${actual[*]-}" ]]
        NETWORK_STATE[proxy_url]=stale
        NETWORK_SSH_SESSION_ENV=(stale)
        configure_network
        [[ "${NETWORK_STATE[selected_network]}" = test-net ]]
        [[ -z "${NETWORK_STATE[proxy_url]}${NETWORK_SSH_SESSION_ENV[*]-}" ]]
        [[ ! -e "$fixture/engine" ]]
    done
)

test_initialize_network_state_clears_outputs() {
    NETWORK_STATE[selected_network]="stale-network"
    NETWORK_STATE[proxy_url]="http://stale"
    NETWORK_SSH_SESSION_ENV=(stale)

    initialize_network_state

    if [[ -z "${NETWORK_STATE[selected_network]}" && -z "${NETWORK_STATE[proxy_url]}" && \
        "${#NETWORK_SSH_SESSION_ENV[@]}" -eq 0 ]]; then
        pass "network initialization clears stale outputs"
    else
        fail "network initialization clears stale outputs"
    fi
}

main() {
    (
        fixture=$(mktemp -d)
        trap 'rm -rf "$fixture"' EXIT
        die() { echo "$*" >&2; exit 1; }
        assert_config_digest_ready() { :; }
        validate_ssh_state_path() { :; }
        validate_ssh_file() { :; }
        CONFIG_DIGEST_LABEL_ARGS=(--label test)
        OBSERVED_RESOURCES=() LAUNCH_ATTEMPTED_RESOURCES=() LAUNCH_ATTEMPTED_HOST_PATHS=()
        NETWORK_NAME=test-net PROXY_NAME=test-proxy PROXY_IMAGE=test-image
        PROJECT_HASH=abcdef123456 OBSERVED_PROXY_STATE=absent
        SSH_DIR=$fixture/state
        SCRIPT_DIR=$JAILBOX_DIR/src
        podman() {
            printf '%s\n' "$*" >> "$fixture/calls"
            case "$fault:$*" in
                plain:'network create '*|internal:'network create --internal '*|external:'network create --label '*|inspect:'network inspect '*|run:'run '*|start:'start '*) return 42 ;;
                partial:'network inspect '*) printf '10.240.1.0/24\n'; return 42 ;;
                retry:'network create --internal '*) [[ $(grep -c '^network create --internal ' "$fixture/calls") -gt 2 ]] || return 42 ;;
            esac
            [[ "$1 $2" != 'network inspect' ]] || printf '10.240.1.0/24\n'
        }
        mkdir() { [[ "$fault" != mkdir ]] || return 42; command mkdir "$@"; }
        chmod() { [[ "$fault" != chmod ]] || return 42; command chmod "$@"; }
        cat() { [[ "$fault" != policy ]] || return 42; command cat "$@"; }
        for fault in plain internal external inspect partial mkdir chmod policy run start; do
            : > "$fixture/calls"
            initialize_network_state
            OBSERVED_RESOURCES=() LAUNCH_ATTEMPTED_RESOURCES=()
            EGRESS_ALLOW=(example.com)
            [[ "$fault" != plain ]] || EGRESS_ALLOW=()
            OBSERVED_PROXY_STATE=absent
            [[ "$fault" != start ]] || OBSERVED_PROXY_STATE=stopped
            # Exhausted subnet retries intentionally die; inspect this case in
            # a child while retaining shared rollback tracking for other cases.
            if [[ "$fault" == internal ]]; then
                if (configure_network); then exit 1; fi
                [[ $(wc -l < "$fixture/calls") -eq 20 ]]
                continue
            fi
            if configure_network 2> "$fixture/error"; then echo "Accepted network failure: $fault" >&2; exit 1; fi
            case "$fault" in
                inspect|partial) grep -Fq 'could not determine subnet of internal network test-net-internal' "$fixture/error" ;;
            esac
            [[ -z "${NETWORK_STATE[selected_network]}" ]]
            case "$fault" in
                plain|external) [[ "${LAUNCH_ATTEMPTED_RESOURCES[*]}" == *network:test-net* ]] ;;
                run) [[ "${LAUNCH_ATTEMPTED_RESOURCES[*]}" == *container:test-proxy* ]] ;;
            esac
            case "$fault" in
                run|start) ;;
                *) if grep -Eq '^(run|start) ' "$fixture/calls"; then exit 1; fi ;;
            esac
        done
        fault=retry OBSERVED_PROXY_STATE=absent
        : > "$fixture/calls"
        OBSERVED_RESOURCES=() LAUNCH_ATTEMPTED_RESOURCES=()
        initialize_network_state
        if configure_network > /dev/null; then
            [[ $(grep -c '^network create --internal ' "$fixture/calls") == 3 && "${NETWORK_STATE[selected_network]}" == test-net-internal ]]
        else
            exit 1
        fi
        fault=reuse OBSERVED_PROXY_STATE=running
        OBSERVED_RESOURCES=(network:test-net-internal network:test-net-external)
        LAUNCH_ATTEMPTED_RESOURCES=()
        : > "$fixture/calls"
        if configure_network > /dev/null; then
            [[ -z "${LAUNCH_ATTEMPTED_RESOURCES[*]-}" ]]
            if grep -Eq '^(network create|run|start)' "$fixture/calls"; then exit 1; fi
        else
            exit 1
        fi
    )
    pass 'conditional network setup stops at required failures and retains attempted creations'
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
    test_configure_proxy_env_rejects_missing_address
    test_effective_egress_allowlist_array_output
    test_initialize_network_state_clears_outputs
    test_proxy_policy_equivalence
    pass "proxy set equivalence, changed-policy refusal, producer failures, and unfiltered mode"

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "network tests: $PASSED passed"
    else
        echo "network tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
