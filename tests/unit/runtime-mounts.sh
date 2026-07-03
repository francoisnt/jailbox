#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/container-runtime.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_contains() {
    local name="$1" file="$2" expected="$3"

    if grep -Fq "$expected" "$file"; then
        pass "$name"
    else
        fail "$name (missing '$expected')"
    fi
}

assert_not_contains() {
    local name="$1" file="$2" unexpected="$3"

    if grep -Fq "$unexpected" "$file"; then
        fail "$name (found '$unexpected')"
    else
        pass "$name"
    fi
}

assert_no_gitconfig_mount() {
    local name="$1" joined

    joined="${GITCONFIG_MOUNT[*]}"
    case "$joined" in
        *".gitconfig"*)
            fail "$name (got: $joined)"
            ;;
        *)
            pass "$name"
            ;;
    esac
}

with_project_state() {
    PROJECT_DIR=$(mktemp -d)
    HOME=$(mktemp -d)
    XDG_CONFIG_HOME=$(mktemp -d)
    XDG_STATE_HOME=$(mktemp -d)
    GIT_CONFIG_NOSYSTEM=1
    export HOME XDG_CONFIG_HOME XDG_STATE_HOME GIT_CONFIG_NOSYSTEM
    MANAGED_USER="jailbox"
    initialize_project_names
}

cleanup_project_state() {
    rm -rf "$PROJECT_DIR" "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
}

test_minimal_gitconfig_mount() {
    local gitconfig_file joined

    with_project_state
    git config --global user.name "Jailbox User"
    git config --global user.email "jailbox@example.test"
    git config --global alias.co checkout
    git config --global credential.helper store

    configure_runtime_mounts
    gitconfig_file="$SSH_DIR/gitconfig"
    joined="${GITCONFIG_MOUNT[*]}"

    case "$joined" in
        *"$gitconfig_file:/home/jailbox/.gitconfig:ro"*)
            pass "generated gitconfig is mounted read-only"
            ;;
        *)
            fail "generated gitconfig is mounted read-only (got: $joined)"
            ;;
    esac
    case "$joined" in
        *"$HOME/.gitconfig"*)
            fail "host gitconfig is not mounted directly"
            ;;
        *)
            pass "host gitconfig is not mounted directly"
            ;;
    esac

    assert_contains "git identity name copied" "$gitconfig_file" "name = Jailbox User"
    assert_contains "git identity email copied" "$gitconfig_file" "email = jailbox@example.test"
    assert_not_contains "git alias omitted" "$gitconfig_file" "[alias]"
    assert_not_contains "credential helper omitted" "$gitconfig_file" "[credential]"

    cleanup_project_state
}

test_no_identity_gets_no_mount() {
    with_project_state
    git config --global alias.co checkout

    configure_runtime_mounts

    assert_no_gitconfig_mount "gitconfig is not mounted without identity"
    if [ -e "$SSH_DIR/gitconfig" ]; then
        fail "empty generated gitconfig is not left behind"
    else
        pass "empty generated gitconfig is not left behind"
    fi

    cleanup_project_state
}

main() {
    echo "runtime mounts tests"
    echo ""

    if ! command -v git >/dev/null 2>&1; then
        echo "git not found; skipping runtime mounts tests"
        return 0
    fi

    test_minimal_gitconfig_mount
    test_no_identity_gets_no_mount

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "runtime mounts tests: $PASSED passed"
    else
        echo "runtime mounts tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
