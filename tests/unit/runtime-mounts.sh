#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/ssh.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/container-runtime.sh"

PASSED=0
FAILED=0
LAUNCH_STATE_DIRS=()

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

    joined="${GITCONFIG_MOUNT[*]-}"
    case "$joined" in
        *".gitconfig"*)
            fail "$name (got: $joined)"
            ;;
        *)
            pass "$name"
            ;;
    esac
}

assert_launch_state_rejects() {
    local name="$1" expected="$2" output

    if output=$(assert_container_launch_state 2>&1); then
        fail "$name"
    elif grep -Fq "$expected" <<< "$output"; then
        pass "$name"
    else
        fail "$name (got: $output)"
    fi
}

with_valid_launch_state() {
    local state_dir

    state_dir=$(mktemp -d)
    LAUNCH_STATE_DIRS+=("$state_dir")
    JAILBOX_IMAGE="jailbox-test-image"
    declare -gA NETWORK_STATE=([selected_network]="jailbox-test-network")
    ROOTFS_FLAG=(--read-only)
    SSHD_RUNTIME_DIR="$state_dir/sshd"
    KEY_FILE="$state_dir/key"
    LOCAL_PORT="50222"
    CONTAINER_NAME="jailbox-test"
    VOLUME_NAME="jailbox-test-home"
    PROJECT_DIR="$state_dir/project"
    REMOTE_PATH="/home/jailbox/project"
    mkdir -p "$SSHD_RUNTIME_DIR" "$PROJECT_DIR"
    : > "$KEY_FILE.pub"
}

cleanup_launch_state() {
    local state_dir

    for state_dir in "${LAUNCH_STATE_DIRS[@]}"; do
        rm -rf "$state_dir"
    done
}

trap cleanup_launch_state EXIT

test_container_launch_preconditions() {
    with_valid_launch_state
    if assert_container_launch_state; then
        pass "complete container launch state accepted"
    else
        fail "complete container launch state accepted"
    fi

    JAILBOX_IMAGE=""
    assert_launch_state_rejects "missing image state rejected" "initialized image state"
    with_valid_launch_state
    NETWORK_STATE[selected_network]=""
    assert_launch_state_rejects "missing network state rejected" "initialized network state"
    with_valid_launch_state
    ROOTFS_FLAG=()
    assert_launch_state_rejects "missing rootfs state rejected" "read-only rootfs state"
    with_valid_launch_state
    rm -f "$KEY_FILE.pub"
    assert_launch_state_rejects "missing SSH credentials rejected" "initialized SSH credentials"
    with_valid_launch_state
    LOCAL_PORT="invalid"
    assert_launch_state_rejects "invalid SSH port rejected" "valid SSH port"
}

test_initialize_container_runtime_state_clears_outputs() {
    READONLY_PATHS=(stale)
    EFFECTIVE_READONLY_PATHS=(stale)
    READONLY_MOUNTS=(stale)
    GITCONFIG_MOUNT=(stale)
    ROOTFS_FLAG=(stale)

    initialize_container_runtime_state

    if [[ "${READONLY_PATHS[*]}" = stale && "${#EFFECTIVE_READONLY_PATHS[@]}" -eq 0 && \
        "${#READONLY_MOUNTS[@]}" -eq 0 && \
        "${#GITCONFIG_MOUNT[@]}" -eq 0 && "${#ROOTFS_FLAG[@]}" -eq 0 ]]; then
        pass "runtime initialization preserves config and clears outputs"
    else
        fail "runtime initialization preserves config and clears outputs"
    fi
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
    initialize_ssh_state
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
    joined="${GITCONFIG_MOUNT[*]-}"

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

    test_container_launch_preconditions
    test_initialize_container_runtime_state_clears_outputs

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
