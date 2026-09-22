#!/bin/bash
# Test cases deliberately export configuration variables and override public
# API declarations inside subshells so each case is isolated; the
# modification being subshell-local is the mechanism, not an oversight.
# Single-quoted check expressions are intentionally unexpanded here: they are
# evaluated inside the loaded subshell by assert_env_config.
# shellcheck disable=SC2016,SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/src/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$JAILBOX_DIR/src/host/api-support.sh"
initialize_public_api_lookups
# shellcheck source=src/host/core/project/hash.sh
source "$JAILBOX_DIR/src/host/core/project/hash.sh"
# shellcheck source=src/host/core/configuration/version.sh
source "$JAILBOX_DIR/src/host/core/configuration/version.sh"
# shellcheck source=src/host/core/checks/host.sh
source "$JAILBOX_DIR/src/host/core/checks/host.sh"
# shellcheck source=src/host/core/project/paths.sh
source "$JAILBOX_DIR/src/host/core/project/paths.sh"
# shellcheck source=src/host/core/configuration/load.sh
source "$JAILBOX_DIR/src/host/core/configuration/load.sh"
# shellcheck source=src/host/core/project/identity.sh
source "$JAILBOX_DIR/src/host/core/project/identity.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

fixture_dir() {
    local dir

    dir=$(mktemp -d)
    (cd "$dir" && pwd -P)
}

# Run load_environment_config in a subshell with the given exported
# NAME=VALUE assignments, then eval the check expression there. The
# subshell keeps exported test variables and loaded values isolated.
assert_env_config() {
    local name="$1" check="$2"
    shift 2
    local dir assignment

    dir=$(fixture_dir)
    if (
        PROJECT_DIR="$dir"
        apply_config_defaults
        for assignment in "$@"; do
            export "${assignment?}"
        done
        load_environment_config >/dev/null 2>&1
        eval "$check"
    ); then
        pass "$name"
    else
        fail "$name"
    fi
    rm -rf "$dir"
}

# Expect load_environment_config to fail with a diagnostic containing every
# given substring (typically the offending variable names).
assert_env_rejects() {
    local name="$1"
    shift
    local -a expected=()
    while [ "$#" -gt 0 ] && [[ "$1" != *=* ]]; do
        expected+=("$1")
        shift
    done
    local dir assignment output substr status

    dir=$(fixture_dir)
    status=0
    output=$(
        (
            PROJECT_DIR="$dir"
            apply_config_defaults
            for assignment in "$@"; do
                export "${assignment?}"
            done
            load_environment_config
        ) 2>&1 >/dev/null
    ) || status=$?
    rm -rf "$dir"

    if [ "$status" -eq 0 ]; then
        fail "$name (unexpectedly loaded)"
        return 0
    fi
    for substr in "${expected[@]}"; do
        case "$output" in
            *"$substr"*) ;;
            *)
                fail "$name (diagnostic missing '$substr'; got: $output)"
                return 0
                ;;
        esac
    done
    pass "$name"
}

test_scalars_and_arrays() {
    assert_env_config "scalar value applied" \
        '[ "$DEV_IMAGE" = "node:22-bookworm" ]' \
        "JAILBOX_CONFIG_DEV_IMAGE=node:22-bookworm"
    assert_env_config "indexed array order preserved" \
        '[ "${#EGRESS_ALLOW[@]}" = 2 ] && [ "${EGRESS_ALLOW[0]}" = github.com ] && [ "${EGRESS_ALLOW[1]}" = api.github.com ]' \
        "JAILBOX_CONFIG_EGRESS_ALLOW_0=github.com" \
        "JAILBOX_CONFIG_EGRESS_ALLOW_1=api.github.com"
    assert_env_config "bare empty variable is an explicitly empty array" \
        '[ "${#READONLY_PATHS[@]}" = 0 ]' \
        "JAILBOX_CONFIG_READONLY_PATHS="
    assert_env_config "values with commas and spaces are legal" \
        '[ "$DEV_IMAGE" = "img with space,and comma" ] && [ "${READONLY_PATHS[0]}" = "dir with space/file name" ]' \
        "JAILBOX_CONFIG_DEV_IMAGE=img with space,and comma" \
        "JAILBOX_CONFIG_READONLY_PATHS_0=dir with space/file name"
    assert_env_config "absent keys receive defaults" \
        '[ -z "$DEV_IMAGE" ] && [ "${#EGRESS_ALLOW[@]}" = 0 ]' \
        "JAILBOX_CONFIG_DEV_TARGET_STAGE=dev"
    assert_env_config "present empty scalar stays empty" \
        '[ -z "$DEV_IMAGE" ] && [ "$DEV_TARGET_STAGE" = dev ]' \
        "JAILBOX_CONFIG_DEV_IMAGE=" \
        "JAILBOX_CONFIG_DEV_TARGET_STAGE=dev"
}

test_resource_limits() {
    assert_env_config "resource limit values applied verbatim" \
        '[ "$MEMORY_LIMIT" = "1.5g" ] && [ "$CPU_LIMIT" = "0.5" ] && [ "$PIDS_LIMIT" = "1024" ]' \
        "JAILBOX_CONFIG_MEMORY_LIMIT=1.5g" \
        "JAILBOX_CONFIG_CPU_LIMIT=0.5" \
        "JAILBOX_CONFIG_PIDS_LIMIT=1024"
    assert_env_config "absent resource limits receive literal defaults" \
        '[ "$MEMORY_LIMIT" = "4g" ] && [ "$CPU_LIMIT" = "2" ] && [ "$PIDS_LIMIT" = "256" ]' \
        "JAILBOX_CONFIG_DEV_TARGET_STAGE=dev"
}

# Scalar keys are declaration-driven: a key declared only in the public-API
# arrays flows through defaults, the environment model, and the file adapter
# with no key-specific code anywhere.
test_declaration_driven_scalars() {
    local dir

    dir=$(fixture_dir)
    if (
        PROJECT_DIR="$dir"
        CONFIG_SCALAR_KEYS+=(SYNTHETIC_LIMIT)
        CONFIG_DEFAULTS+=("SYNTHETIC_LIMIT=fallback")
        initialize_public_api_lookups
        apply_config_defaults
        export JAILBOX_CONFIG_DEV_TARGET_STAGE=dev
        load_environment_config >/dev/null 2>&1
        [ "$SYNTHETIC_LIMIT" = fallback ]
    ); then
        pass "declared key receives its default without key-specific code"
    else
        fail "declared key receives its default without key-specific code"
    fi
    if (
        PROJECT_DIR="$dir"
        CONFIG_SCALAR_KEYS+=(SYNTHETIC_LIMIT)
        CONFIG_DEFAULTS+=("SYNTHETIC_LIMIT=fallback")
        initialize_public_api_lookups
        apply_config_defaults
        export JAILBOX_CONFIG_SYNTHETIC_LIMIT=custom
        load_environment_config >/dev/null 2>&1
        [ "$SYNTHETIC_LIMIT" = custom ]
    ); then
        pass "environment value reaches a declared key without key-specific code"
    else
        fail "environment value reaches a declared key without key-specific code"
    fi
    printf 'SYNTHETIC_LIMIT=fromfile\n' > "$dir/jailbox.conf"
    if (
        PROJECT_DIR="$dir"
        CONFIG_SCALAR_KEYS+=(SYNTHETIC_LIMIT)
        CONFIG_DEFAULTS+=("SYNTHETIC_LIMIT=fallback")
        initialize_public_api_lookups
        apply_config_defaults
        load_environment_config >/dev/null 2>&1
        [ "$SYNTHETIC_LIMIT" = fallback ]
    ); then
        pass "machine defaults ignore file values for newly declared keys"
    else
        fail "machine defaults ignore file values for newly declared keys"
    fi
    rm -rf "$dir"
}

test_many_member_array() {
    local dir i
    local -a assignments=()

    dir=$(fixture_dir)
    for ((i = 0; i < 300; i++)); do
        assignments+=("JAILBOX_CONFIG_READONLY_PATHS_${i}=path-${i}")
    done
    if (
        PROJECT_DIR="$dir"
        apply_config_defaults
        local assignment
        for assignment in "${assignments[@]}"; do
            export "${assignment?}"
        done
        load_environment_config >/dev/null 2>&1
        [ "${#READONLY_PATHS[@]}" = 300 ] && \
            [ "${READONLY_PATHS[0]}" = path-0 ] && \
            [ "${READONLY_PATHS[299]}" = path-299 ]
    ); then
        pass "many-member array accepted with order preserved"
    else
        fail "many-member array accepted with order preserved"
    fi
    rm -rf "$dir"
}

test_rejections() {
    assert_env_rejects "control character in scalar rejected naming variable" \
        "JAILBOX_CONFIG_DEV_IMAGE" "control character" \
        "JAILBOX_CONFIG_DEV_IMAGE=$(printf 'a\1b')"
    assert_env_rejects "newline value rejected naming variable" \
        "JAILBOX_CONFIG_DEV_IMAGE" "control character" \
        "JAILBOX_CONFIG_DEV_IMAGE=$(printf 'a\nb')x"
    assert_env_rejects "control character in array member rejected" \
        "JAILBOX_CONFIG_READONLY_PATHS_0" "control character" \
        "JAILBOX_CONFIG_READONLY_PATHS_0=$(printf 'a\tb')"
    assert_env_rejects "leading-zero index rejected" \
        "JAILBOX_CONFIG_READONLY_PATHS_01" \
        "JAILBOX_CONFIG_READONLY_PATHS_01=x"
    assert_env_rejects "alphabetic suffix rejected" \
        "JAILBOX_CONFIG_READONLY_PATHS_X" \
        "JAILBOX_CONFIG_READONLY_PATHS_X=x"
    assert_env_rejects "unknown name rejected" \
        "JAILBOX_CONFIG_NOPE" \
        "JAILBOX_CONFIG_NOPE=1"
    assert_env_rejects "unknown indexed key rejected" \
        "JAILBOX_CONFIG_NOPE_0" \
        "JAILBOX_CONFIG_NOPE_0=1"
    assert_env_rejects "no editor key exists in the machine namespace" \
        "JAILBOX_CONFIG_EDITOR" \
        "JAILBOX_CONFIG_EDITOR=code"
    assert_env_rejects "lowercase namespace variable rejected" \
        "JAILBOX_CONFIG_bad" \
        "JAILBOX_CONFIG_bad=1"
    assert_env_rejects "non-empty bare array rejected" \
        "JAILBOX_CONFIG_EGRESS_ALLOW" \
        "JAILBOX_CONFIG_EGRESS_ALLOW=github.com"
    assert_env_rejects "bare-plus-indexed form rejected" \
        "JAILBOX_CONFIG_EGRESS_ALLOW" \
        "JAILBOX_CONFIG_EGRESS_ALLOW=" \
        "JAILBOX_CONFIG_EGRESS_ALLOW_0=github.com"
    assert_env_rejects "gap names both the member and the missing variable" \
        "JAILBOX_CONFIG_READONLY_PATHS_2" "JAILBOX_CONFIG_READONLY_PATHS_1" \
        "JAILBOX_CONFIG_READONLY_PATHS_0=a" \
        "JAILBOX_CONFIG_READONLY_PATHS_2=b"
    assert_env_rejects "empty array member rejected" \
        "JAILBOX_CONFIG_READONLY_PATHS_0" \
        "JAILBOX_CONFIG_READONLY_PATHS_0="
    assert_env_rejects "semantic validation applies to environment values" \
        "localhost" \
        "JAILBOX_CONFIG_EGRESS_ALLOW_0=localhost"
    assert_env_rejects "lexical path validation applies to environment values" \
        "READONLY_PATHS" \
        "JAILBOX_CONFIG_READONLY_PATHS_0=../outside"
}

test_exclusivity_and_notice() {
    local dir output

    dir=$(fixture_dir)
    printf 'DEV_IMAGE=fromfile\n' > "$dir/jailbox.conf"
    output=$(
        (
            PROJECT_DIR="$dir"
            apply_config_defaults
            export JAILBOX_CONFIG_DEV_TARGET_STAGE=dev
            load_environment_config
            [ -z "$DEV_IMAGE" ] || die "file value leaked into environment configuration"
        ) 2>&1
    ) || {
        fail "environment configuration excludes the file (got: $output)"
        rm -rf "$dir"
        return 0
    }
    pass "environment configuration excludes the file"
    [[ -z "$output" ]] || fail "machine configuration must not inspect or report a file"

    # A malformed file must not matter when environment configuration is
    # present: the file is not read at all.
    printf 'UNKNOWN=value\n' > "$dir/jailbox.conf"
    if (
        PROJECT_DIR="$dir"
        apply_config_defaults
        export JAILBOX_CONFIG_DEV_TARGET_STAGE=dev
        load_environment_config
    ) >/dev/null 2>&1; then
        pass "malformed file ignored when environment configuration is present"
    else
        fail "malformed file ignored when environment configuration is present"
    fi

    # Without the file, environment configuration is complete on its own: no
    # initialization anchor is required.
    rm "$dir/jailbox.conf"
    if (
        PROJECT_DIR="$dir"
        apply_config_defaults
        export JAILBOX_CONFIG_DEV_TARGET_STAGE=dev
        load_environment_config up
    ) >/dev/null 2>&1; then
        pass "environment configuration needs no jailbox.conf anchor"
    else
        fail "environment configuration needs no jailbox.conf anchor"
    fi
    rm -rf "$dir"
}

test_unexported_not_interface() {
    local dir

    dir=$(fixture_dir)
    printf 'DEV_IMAGE=fromfile\n' > "$dir/jailbox.conf"
    if (
        PROJECT_DIR="$dir"
        apply_config_defaults
        # shellcheck disable=SC2034 # An unexported name must not be consumed.
        JAILBOX_CONFIG_DEV_IMAGE=shadow
        load_environment_config >/dev/null 2>&1
        [ -z "$DEV_IMAGE" ]
    ); then
        pass "unexported shell variables are not part of the interface"
    else
        fail "unexported shell variables are not part of the interface"
    fi
    rm -rf "$dir"
}

test_declaration_integrity() {
    if (
        CONFIG_SCALAR_KEYS+=(EGRESS_ALLOW)
        validate_public_api_declaration
    ) >/dev/null 2>&1; then
        fail "duplicate declaration class rejected"
    else
        pass "duplicate declaration class rejected"
    fi
    if (
        CONFIG_SCALAR_KEYS+=(NEW_KEY)
        validate_public_api_declaration
    ) >/dev/null 2>&1; then
        fail "declared key without default rejected"
    else
        pass "declared key without default rejected"
    fi
    if (
        CONFIG_DEFAULTS+=("STRAY=")
        validate_public_api_declaration
    ) >/dev/null 2>&1; then
        fail "default without declared key rejected"
    else
        pass "default without declared key rejected"
    fi
    if (
        FRONTEND_SCALAR_KEYS+=(DEV_IMAGE)
        validate_public_api_declaration
    ) >/dev/null 2>&1; then
        fail "machine/frontend overlap rejected"
    else
        pass "machine/frontend overlap rejected"
    fi
    if (
        CONFIG_SCALAR_KEYS+=(EGRESS_ALLOW_0)
        CONFIG_DEFAULTS+=("EGRESS_ALLOW_0=")
        validate_public_api_declaration
    ) >/dev/null 2>&1; then
        fail "indexed-member key collision rejected"
    else
        pass "indexed-member key collision rejected"
    fi
    if validate_public_api_declaration >/dev/null 2>&1; then
        pass "shipped declaration passes integrity checks"
    else
        fail "shipped declaration passes integrity checks"
    fi
}

main() {
    local value
    assert_env_config "home is persistent by default" '[ "$EPHEMERAL_HOME" = false ]' \
        JAILBOX_CONFIG_READONLY_PATHS=
    for value in true false; do
        assert_env_config "home accepts $value" "[ \"\$EPHEMERAL_HOME\" = $value ]" \
            "JAILBOX_CONFIG_EPHEMERAL_HOME=$value"
    done
    for value in '' TRUE False 0 1 yes no ' true' 'false '; do
        assert_env_rejects "invalid home boolean '$value'" 'invalid EPHEMERAL_HOME' \
            "JAILBOX_CONFIG_EPHEMERAL_HOME=$value"
    done
    test_scalars_and_arrays
    test_resource_limits
    test_declaration_driven_scalars
    test_many_member_array
    test_rejections
    test_exclusivity_and_notice
    test_unexported_not_interface
    test_declaration_integrity

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "environment config tests: $PASSED passed"
    else
        echo "environment config tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
