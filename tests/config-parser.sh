#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/lib/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/lib/common.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

with_config() {
    local body="$1"
    local dir

    dir=$(mktemp -d)
    printf '%s\n' "$body" > "$dir/jailbox.conf"
    printf '%s\n' "$dir"
}

load_config_from_dir() {
    local dir="$1"

    # shellcheck disable=SC2034  # consumed by sourced common.sh
    PROJECT_DIR="$dir"
    apply_config_defaults
    load_project_config
}

assert_loads() {
    local name="$1"
    local body="$2"
    local dir

    dir=$(with_config "$body")
    if load_config_from_dir "$dir"; then
        pass "$name"
    else
        fail "$name"
    fi
    rm -rf "$dir"
}

assert_rejects() {
    local name="$1"
    local body="$2"
    local dir

    dir=$(with_config "$body")
    if (load_config_from_dir "$dir") >/dev/null 2>&1; then
        fail "$name"
    else
        pass "$name"
    fi
    rm -rf "$dir"
}

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

test_values() {
    local dir

    dir=$(with_config '
# Scalars
DEV_IMAGE="docker.io/library/debian:slim"
DEV_CONTAINERFILE='\''./Dockerfile'\''
DEV_BUILD_CONTEXT=.
DEV_TARGET_STAGE=dev
REMOTE_PATH=/workspace/project

# Arrays
EGRESS_ALLOW="github.com,api.github.com"
')
    load_config_from_dir "$dir"
    assert_eq "scalar value parsed" "docker.io/library/debian:slim" "$DEV_IMAGE"
    assert_eq "single-quoted scalar value parsed" "./Dockerfile" "$DEV_CONTAINERFILE"
    assert_eq "remote path parsed" "/workspace/project" "$REMOTE_PATH"
    assert_eq "array length parsed" "2" "${#EGRESS_ALLOW[@]}"
    assert_eq "array item parsed" "api.github.com" "${EGRESS_ALLOW[1]}"
    rm -rf "$dir"
}

test_injection_rejected() {
    local marker="/tmp/jailbox-config-parser-pwned-$$"

    rm -f "$marker"
    assert_rejects "command substitution rejected" "DEV_IMAGE=\$(touch $marker)"
    assert_rejects "semicolon rejected" "DEV_IMAGE=node:22;touch-$marker"
    assert_rejects "legacy bash array rejected" 'EGRESS_ALLOW=("github.com" "api.github.com")'
    if [ -e "$marker" ]; then
        fail "injection marker was created"
        rm -f "$marker"
    else
        pass "injection marker not created"
    fi
}

main() {
    assert_loads "empty config loads" ""
    assert_loads "comments load" $'# comment\n\nDEV_IMAGE=node:22'
    test_values

    assert_rejects "spaces around = rejected" "DEV_IMAGE = node:22"
    assert_loads "quoted value loads" 'DEV_IMAGE="node:22"'
    assert_rejects "mismatched quoted value rejected" 'DEV_IMAGE="node:22'
    assert_rejects "embedded quoted value rejected" 'DEV_IMAGE=node"22'
    assert_rejects "unknown key rejected" "UNKNOWN=value"
    assert_rejects "duplicate key rejected" $'DEV_IMAGE=a\nDEV_IMAGE=b'
    assert_rejects "relative remote path rejected" "REMOTE_PATH=workspace"
    assert_rejects "bad egress host rejected" "EGRESS_ALLOW=https://github.com"
    assert_rejects "whitespace in value rejected" "DEV_IMAGE=node 22"
    test_injection_rejected

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "config parser tests: $PASSED passed"
    else
        echo "config parser tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
