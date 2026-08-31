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

# Fixture directories are supplied to code that rejects every symlinked
# component of a trusted input path. macOS places TMPDIR under the symlinked
# /var, so canonicalize unconditionally; tests that need a symlinked spelling
# build one explicitly from the canonical directory.
fixture_dir() {
    local dir

    dir=$(mktemp -d)
    (cd "$dir" && pwd -P)
}

with_config() {
    local body="$1"
    local dir

    dir=$(fixture_dir)
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

assert_cli_exit() {
    local name expected_status

    name="$1"
    expected_status="$2"
    shift 2

    local actual_status
    if "$@" >/dev/null 2>&1; then
        actual_status=0
    else
        actual_status=$?
    fi
    assert_eq "$name" "$expected_status" "$actual_status"
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
READONLY_PATHS="Makefile,.husky,scripts/deploy.sh"
')
    load_config_from_dir "$dir"
    assert_eq "scalar value parsed" "docker.io/library/debian:slim" "$DEV_IMAGE"
    assert_eq "single-quoted scalar value parsed" "./Dockerfile" "$DEV_CONTAINERFILE"
    assert_eq "editor value parsed" "code" "$EDITOR"
    assert_eq "array length parsed" "2" "${#EGRESS_ALLOW[@]}"
    assert_eq "array item parsed" "api.github.com" "${EGRESS_ALLOW[1]}"
    assert_eq "readonly paths length parsed" "3" "${#READONLY_PATHS[@]}"
    assert_eq "readonly paths item parsed" "scripts/deploy.sh" "${READONLY_PATHS[2]}"
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
    local help_output invalid_project

    assert_cli_exit "config option requires a value" 2 "$JAILBOX_UNDER_TEST" --config
    assert_cli_exit "config option rejects an empty value" 2 "$JAILBOX_UNDER_TEST" --config ""
    assert_cli_exit "misplaced config option rejected" 2 "$JAILBOX_UNDER_TEST" doctor --config lane.conf
    assert_cli_exit "duplicate config option rejected" 2 \
        "$JAILBOX_UNDER_TEST" --config lane.conf --config other.conf
    # shellcheck disable=SC2016  # $1 is intentionally expanded by bash -c.
    assert_cli_exit "unexpected command operand rejected" 2 bash -c \
        'source "$1/host/public-api.sh"; source "$1/host/common.sh"; source "$1/host/preflight.sh"; parse_args doctor extra' \
        bash "$JAILBOX_DIR"
    assert_cli_exit "unknown leading option rejected before config access" 2 \
        "$JAILBOX_UNDER_TEST" --unknown
    assert_cli_exit "equals-form config option rejected" 2 \
        "$JAILBOX_UNDER_TEST" --config=lane.conf

    help_output=$("$JAILBOX_UNDER_TEST" --help)
    case "$help_output" in
        *"--config PATH"*) pass "help shows config value placeholder" ;;
        *) fail "help shows config value placeholder" ;;
    esac

    invalid_project=$(with_config "UNKNOWN=value")
    if (cd "$invalid_project" && "$JAILBOX_UNDER_TEST" --unknown) >/dev/null 2>&1; then
        fail "unknown command rejected before malformed default config"
    elif [ "$?" -eq 2 ]; then
        pass "unknown command rejected before malformed default config"
    else
        fail "unknown command rejected before malformed default config"
    fi
    rm -rf "$invalid_project"
}

test_selected_config() {
    local project external output

    project=$(fixture_dir)
    external=$(fixture_dir)
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
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "in-project config symlink rejected"
    else
        pass "in-project config symlink rejected"
    fi

    ln -s "$external/lane config.conf" "$project/config/escape.conf"
    CONFIG_PATH_ARG="$project/config/escape.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "project config symlink to external target rejected"
    else
        pass "project config symlink to external target rejected"
    fi

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

test_config_selection_precedence() {
    local project external

    project=$(fixture_dir)
    external=$(fixture_dir)
    PROJECT_DIR="$project"

    CONFIG_PATH_ARG=""
    CONFIG_FILE=stale
    prepare_config_selection doctor
    assert_eq "optional command with no config clears stale selection" "" "$CONFIG_FILE"

    printf 'DEV_IMAGE=default\n' > "$project/jailbox.conf"
    prepare_config_selection
    assert_eq "default project config selected" "$project/jailbox.conf" "$CONFIG_FILE"

    printf 'UNKNOWN=bad-default\n' > "$project/jailbox.conf"
    printf 'DEV_IMAGE=explicit\n' > "$external/lane.conf"
    CONFIG_PATH_ARG="$external/lane.conf"
    apply_config_defaults
    prepare_config_selection
    load_project_config
    assert_eq "explicit config bypasses malformed default" "explicit" "$DEV_IMAGE"

    CONFIG_PATH_ARG="./lane.conf"
    if (cd "$external" && prepare_config_selection && [ "$CONFIG_FILE" = "$external/lane.conf" ]); then
        pass "relative explicit config resolves from invocation directory"
    else
        fail "relative explicit config resolves from invocation directory"
    fi

    ln -s missing-target.conf "$external/dangling.conf"
    CONFIG_PATH_ARG="$external/dangling.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "dangling selected config symlink rejected"
    else
        pass "dangling selected config symlink rejected"
    fi

    rm -rf "$project" "$external"
}

test_config_path_diagnostics() {
    local project output

    project=$(fixture_dir)
    PROJECT_DIR="$project"
    : > "$project/jailbox.conf"
    CONFIG_PATH_ARG="$project/missing.conf"
    output=$( (prepare_config_selection) 2>&1 || true)
    case "$output" in
        *"config path does not exist"*"$project/missing.conf"*)
            pass "missing selected config diagnostic names path"
            ;;
        *)
            fail "missing selected config diagnostic names path"
            ;;
    esac

    rm -rf "$project"
}

test_trusted_config_inputs() {
    local project external external_link

    project=$(fixture_dir)
    external=$(fixture_dir)
    external_link="${external}-link"
    printf 'DEV_IMAGE=selected\n' > "$external/lane.conf"
    ln -s "$external" "$external_link"
    PROJECT_DIR="$project"
    : > "$project/jailbox.conf"

    CONFIG_PATH_ARG="$external_link/lane.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "external config through symlinked prefix rejected"
    else
        pass "external config through symlinked prefix rejected"
    fi
    CONFIG_PATH_ARG="$external/lane.conf"
    if prepare_config_selection; then
        pass "external config through physical path accepted"
    else
        fail "external config through physical path accepted"
    fi

    rm "$project/jailbox.conf"
    mkdir "$project/jailbox.conf"
    CONFIG_PATH_ARG="$external/lane.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "non-regular default config rejected under external selection"
    else
        pass "non-regular default config rejected under external selection"
    fi
    rmdir "$project/jailbox.conf"
    printf 'DEV_IMAGE=default\n' > "$project/jailbox.conf"
    chmod 000 "$project/jailbox.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "unreadable default config rejected under external selection"
    else
        pass "unreadable default config rejected under external selection"
    fi
    chmod 600 "$project/jailbox.conf"
    rm "$project/jailbox.conf"
    printf 'DEV_IMAGE=default\n' > "$project/default-target.conf"
    ln -s default-target.conf "$project/jailbox.conf"
    if (prepare_config_selection) >/dev/null 2>&1; then
        fail "symlinked default config rejected under external selection"
    else
        pass "symlinked default config rejected under external selection"
    fi

    rm -f "$external_link"
    rm -rf "$project" "$external"
}

test_launch_requires_default_anchor() {
    local project external output command

    project=$(fixture_dir)
    external=$(fixture_dir)
    printf 'DEV_IMAGE=selected\n' > "$external/lane.conf"
    PROJECT_DIR="$project"
    CONFIG_PATH_ARG="$external/lane.conf"
    output=$( (prepare_config_selection) 2>&1 || true)
    case "$output" in
        *"Project is not initialized"*"jailbox init"*)
            pass "bare launch requires default anchor before explicit config"
            ;;
        *)
            fail "bare launch requires default anchor before explicit config"
            ;;
    esac
    # Inspection and lifecycle commands must stay usable before initialization.
    for command in doctor ssh-config --clean; do
        if prepare_config_selection "$command"; then
            pass "$command does not require the default anchor"
        else
            fail "$command does not require the default anchor"
        fi
    done
    rm -rf "$project" "$external"
}

test_uninstall_ignores_project_config() {
    local project output

    project=$(fixture_dir)
    ln -s missing.conf "$project/jailbox.conf"
    output=$( (cd "$project"; "$JAILBOX_UNDER_TEST" --uninstall) 2>&1 || true)
    case "$output" in
        *"not an installed copy"*) pass "uninstall ignores project config" ;;
        *) fail "uninstall ignores project config (got: $output)" ;;
    esac
    rm -rf "$project"
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
    assert_loads "readonly paths loads" "READONLY_PATHS=Makefile,.husky"
    assert_loads "empty readonly paths loads" "READONLY_PATHS="
    assert_rejects "removed readonly extra rejected" "READONLY_EXTRA=Makefile"
    assert_rejects "absolute readonly paths rejected" "READONLY_PATHS=/etc/passwd"
    assert_rejects "traversing readonly paths rejected" "READONLY_PATHS=../outside"
    assert_rejects "embedded dotdot readonly paths rejected" "READONLY_PATHS=docs/../.git"
    assert_rejects "dot readonly paths rejected" "READONLY_PATHS=."
    assert_rejects "trailing slash readonly paths rejected" "READONLY_PATHS=.husky/"
    assert_rejects "colon readonly paths rejected" "READONLY_PATHS=docs:ro"
    assert_rejects "empty path component rejected" "READONLY_PATHS=docs//api"
    assert_rejects "duplicate readonly paths rejected" "READONLY_PATHS=Makefile,Makefile"
    assert_rejects "whitespace in value rejected" "DEV_IMAGE=node 22"
    test_injection_rejected
    test_cli_lookup_injection_rejected
    test_help_ignores_invalid_config
    test_global_config_args
    test_selected_config
    test_explicit_help_ignores_missing_config
    test_config_selection_precedence
    test_config_path_diagnostics
    test_trusted_config_inputs
    test_launch_requires_default_anchor
    test_uninstall_ignores_project_config

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "config parser tests: $PASSED passed"
    else
        echo "config parser tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
