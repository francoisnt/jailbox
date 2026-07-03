#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local name="$1" expected="$2" actual="$3"

    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name (expected '$expected', got '$actual')"
    fi
}

assert_not_prefix() {
    local name="$1" prefix="$2" actual="$3"

    case "$actual" in
        "$prefix"/*)
            fail "$name ('$actual' should not be below '$prefix')"
            ;;
        *)
            pass "$name"
            ;;
    esac
}

test_project_state_paths() {
    local project_dir state_home hash

    project_dir=$(mktemp -d)
    state_home=$(mktemp -d)
    PROJECT_DIR="$project_dir"
    XDG_STATE_HOME="$state_home"

    initialize_project_names
    hash=$(jailbox_project_hash_for_path "$project_dir")

    assert_eq "SSH state uses XDG project state dir" "$state_home/jailbox/projects/$hash" "$SSH_DIR"
    assert_eq "SSH config uses project state dir" "$state_home/jailbox/projects/$hash/ssh_config" "$SSH_CONFIG"
    assert_eq "editor profile remains in XDG state" "$state_home/jailbox/editor-profiles/$hash" "$JAILBOX_EDITOR_USER_DATA"
    assert_not_prefix "SSH state is outside project" "$project_dir" "$SSH_DIR"

    rm -rf "$project_dir" "$state_home"
}

main() {
    echo "project state tests"
    echo ""

    test_project_state_paths

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "project state tests: $PASSED passed"
    else
        echo "project state tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
