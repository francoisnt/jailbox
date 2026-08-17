#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/preflight.sh"

PASSED=0
FAILED=0
JAILBOX_UNDER_TEST="$JAILBOX_DIR/jailbox"

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
    CONFIG_PATH_ARG=""
    prepare_config_selection
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
EDITOR=code

# Arrays
EGRESS_ALLOW="github.com,api.github.com"
READONLY_EXTRA="Makefile,.husky,scripts/deploy.sh"
')
    load_config_from_dir "$dir"
    assert_eq "scalar value parsed" "docker.io/library/debian:slim" "$DEV_IMAGE"
    assert_eq "single-quoted scalar value parsed" "./Dockerfile" "$DEV_CONTAINERFILE"
    assert_eq "editor value parsed" "code" "$EDITOR"
    assert_eq "array length parsed" "2" "${#EGRESS_ALLOW[@]}"
    assert_eq "array item parsed" "api.github.com" "${EGRESS_ALLOW[1]}"
    assert_eq "readonly extra length parsed" "3" "${#READONLY_EXTRA[@]}"
    assert_eq "readonly extra item parsed" "scripts/deploy.sh" "${READONLY_EXTRA[2]}"
    rm -rf "$dir"
}

test_injection_rejected() {
    local marker="/tmp/jailbox-config-parser-pwned-$$"

    rm -f "$marker"
    assert_rejects "command substitution rejected" "DEV_IMAGE=\$(touch $marker)"
    assert_rejects "associative subscript injection rejected" \
        "BAD[\$(touch $marker)]=value"
    assert_rejects "semicolon rejected" "DEV_IMAGE=node:22;touch-$marker"
    assert_rejects "legacy bash array rejected" 'EGRESS_ALLOW=("github.com" "api.github.com")'
    if [ -e "$marker" ]; then
        fail "injection marker was created"
        rm -f "$marker"
    else
        pass "injection marker not created"
    fi
}

test_cli_lookup_injection_rejected() {
    local marker="/tmp/jailbox-cli-lookup-pwned-$$"

    rm -f "$marker"
    if is_cli_flag_allowed "BAD[\$(touch $marker)]"; then
        fail "associative CLI lookup rejects invalid argument"
    else
        pass "associative CLI lookup rejects invalid argument"
    fi
    if [ -e "$marker" ]; then
        fail "CLI lookup injection marker was created"
        rm -f "$marker"
    else
        pass "CLI lookup injection marker not created"
    fi
}

test_help_ignores_invalid_config() {
    local dir

    dir=$(with_config "UNKNOWN=value")
    if (cd "$dir" && "$JAILBOX_DIR/jailbox" --help) >/dev/null 2>&1; then
        pass "--help ignores invalid project config"
    else
        fail "--help ignores invalid project config"
    fi
    rm -rf "$dir"
}

test_global_config_args() {
    if "$JAILBOX_UNDER_TEST" --config >/dev/null 2>&1; then
        fail "config option requires a value"
    else
        pass "config option requires a value"
    fi
    if "$JAILBOX_UNDER_TEST" --config "" >/dev/null 2>&1; then
        fail "config option rejects an empty value"
    else
        pass "config option rejects an empty value"
    fi
    if "$JAILBOX_UNDER_TEST" doctor --config lane.conf >/dev/null 2>&1; then
        fail "misplaced config option rejected"
    else
        pass "misplaced config option rejected"
    fi
    if "$JAILBOX_UNDER_TEST" --config lane.conf --config other.conf >/dev/null 2>&1; then
        fail "duplicate config option rejected"
    else
        pass "duplicate config option rejected"
    fi
    if (parse_args doctor extra) >/dev/null 2>&1; then
        fail "unexpected command operand rejected"
    else
        pass "unexpected command operand rejected"
    fi
}

test_selected_config() {
    local project external output

    project=$(mktemp -d)
    external=$(mktemp -d)
    printf 'DEV_IMAGE=default\n' > "$project/jailbox.conf"
    printf 'DEV_IMAGE=selected\n' > "$external/lane config.conf"
    PROJECT_DIR="$project"
    apply_config_defaults
    CONFIG_PATH_ARG="$external/lane config.conf"
    prepare_config_selection
    load_project_config
    assert_eq "selected config replaces project config" "selected" "$DEV_IMAGE"
    assert_eq "external config selected canonically" "$external/lane config.conf" "$CONFIG_FILE"

    mkdir -p "$project/config"
    printf 'DEV_IMAGE=inside\n' > "$project/config/lane.conf"
    CONFIG_PATH_ARG="$project/config/lane.conf"
    prepare_config_selection
    assert_eq "in-project config selected canonically" "$project/config/lane.conf" "$CONFIG_FILE"

    printf 'DEV_IMAGE=target\n' > "$project/config/target.conf"
    ln -s target.conf "$project/config/link.conf"
    CONFIG_PATH_ARG="$project/config/link.conf"
    prepare_config_selection
    assert_eq "in-project config symlink resolves target" "$project/config/target.conf" "$CONFIG_FILE"

    ln -s "$external/lane config.conf" "$project/config/escape.conf"
    CONFIG_PATH_ARG="$project/config/escape.conf"
    prepare_config_selection
    assert_eq "in-project symlink resolves external target" "$external/lane config.conf" "$CONFIG_FILE"

    CONFIG_PATH_ARG="$external/missing.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "missing selected config rejected"
    else
        pass "missing selected config rejected"
    fi

    mkdir "$external/config-dir"
    CONFIG_PATH_ARG="$external/config-dir"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "non-regular selected config rejected"
    else
        pass "non-regular selected config rejected"
    fi

    printf 'DEV_IMAGE=unreadable\n' > "$external/unreadable.conf"
    chmod 000 "$external/unreadable.conf"
    CONFIG_PATH_ARG="$external/unreadable.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "unreadable selected config rejected"
    else
        pass "unreadable selected config rejected"
    fi
    chmod 600 "$external/unreadable.conf"

    printf 'DEV_IMAGE=dash\n' > "$external/-lane.conf"
    if (cd "$external" && CONFIG_PATH_ARG=-lane.conf prepare_config_selection && \
        [ "$CONFIG_FILE" = "$external/-lane.conf" ]); then
        pass "selected config path may begin with dash"
    else
        fail "selected config path may begin with dash"
    fi

    printf 'UNKNOWN=value\n' > "$external/bad.conf"
    CONFIG_PATH_ARG="$external/bad.conf"
    prepare_config_selection
    output=$( (load_project_config) 2>&1 || true)
    case "$output" in
        *"$external/bad.conf"*"line 1"*) pass "selected config diagnostics name file and line" ;;
        *) fail "selected config diagnostics name file and line" ;;
    esac

    rm -rf "$project" "$external"
}

test_explicit_help_ignores_missing_config() {
    if "$JAILBOX_UNDER_TEST" --config /does/not/exist --help >/dev/null 2>&1; then
        pass "--config PATH --help ignores missing selected config"
    else
        fail "--config PATH --help ignores missing selected config"
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
    assert_rejects "remote path config rejected" "REMOTE_PATH=/workspace/project"
    assert_rejects "bad editor rejected" "EDITOR=vim"
    assert_rejects "bad egress host rejected" "EGRESS_ALLOW=https://github.com"
    assert_rejects "single-label egress host rejected" "EGRESS_ALLOW=localhost"
    assert_loads "readonly extra loads" "READONLY_EXTRA=Makefile,.husky"
    assert_rejects "absolute readonly extra rejected" "READONLY_EXTRA=/etc/passwd"
    assert_rejects "traversing readonly extra rejected" "READONLY_EXTRA=../outside"
    assert_rejects "embedded dotdot readonly extra rejected" "READONLY_EXTRA=docs/../.git"
    assert_rejects "dot readonly extra rejected" "READONLY_EXTRA=."
    assert_rejects "trailing slash readonly extra rejected" "READONLY_EXTRA=.husky/"
    assert_rejects "whitespace in value rejected" "DEV_IMAGE=node 22"
    test_injection_rejected
    test_cli_lookup_injection_rejected
    test_help_ignores_invalid_config
    test_global_config_args
    test_selected_config
    test_explicit_help_ignores_missing_config

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "config parser tests: $PASSED passed"
    else
        echo "config parser tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
