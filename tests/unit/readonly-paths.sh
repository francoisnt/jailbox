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

# configure_readonly_paths consults SCRIPT_DIR for the in-project submodule
# case; point it at the repo checkout, which never lives under the temp
# project directories used here.
SCRIPT_DIR="$JAILBOX_DIR"
REMOTE_PATH="/home/jailbox/project"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

path_count() {
    local candidate="$1" path count
    count=0
    for path in "${READONLY_PATHS[@]}"; do
        [ "$path" = "$candidate" ] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

assert_listed_once() {
    local name="$1" path="$2"
    if [ "$(path_count "$path")" = 1 ]; then
        pass "$name"
    else
        fail "$name (found $(path_count "$path") entries for '$path')"
    fi
}

assert_not_listed() {
    local name="$1" path="$2"
    if [ "$(path_count "$path")" = 0 ]; then
        pass "$name"
    else
        fail "$name ('$path' should not be listed)"
    fi
}

with_project() {
    PROJECT_DIR=$(mktemp -d)
    apply_config_defaults
}

test_defaults() {
    with_project
    configure_readonly_paths
    assert_listed_once "default .git/config listed" ".git/config"
    assert_listed_once "default jailbox.conf listed" "jailbox.conf"
    assert_not_listed "project .jailbox is not protected state" ".jailbox"
    rm -rf "$PROJECT_DIR"
}

test_readonly_extra() {
    with_project
    READONLY_EXTRA=(Makefile .env scripts/deploy.sh)
    configure_readonly_paths
    assert_listed_once "extra path appended" "Makefile"
    assert_listed_once "nested extra path appended" "scripts/deploy.sh"
    assert_listed_once "extra duplicating default is deduplicated" ".env"
    rm -rf "$PROJECT_DIR"
}

test_dev_containerfile() {
    with_project
    DEV_CONTAINERFILE="docker/dev.Dockerfile"
    configure_readonly_paths
    assert_listed_once "custom containerfile listed" "docker/dev.Dockerfile"
    rm -rf "$PROJECT_DIR"

    with_project
    DEV_CONTAINERFILE="./Dockerfile"
    configure_readonly_paths
    assert_listed_once "dot-slash containerfile deduplicated with default" "Dockerfile"
    rm -rf "$PROJECT_DIR"

    with_project
    DEV_CONTAINERFILE="$PROJECT_DIR/docker/dev.Dockerfile"
    configure_readonly_paths
    assert_listed_once "absolute in-project containerfile listed relative" "docker/dev.Dockerfile"
    rm -rf "$PROJECT_DIR"

    with_project
    DEV_CONTAINERFILE="../outside/Dockerfile"
    configure_readonly_paths
    assert_not_listed "out-of-project containerfile not listed" "../outside/Dockerfile"
    assert_not_listed "out-of-project containerfile not listed resolved" "outside/Dockerfile"
    rm -rf "$PROJECT_DIR"
}

test_mounts() {
    local out_file joined

    with_project
    mkdir -p "$PROJECT_DIR/scripts"
    touch "$PROJECT_DIR/scripts/deploy.sh"
    READONLY_EXTRA=(scripts/deploy.sh missing-file)
    configure_readonly_paths

    out_file=$(mktemp)
    build_readonly_mounts > "$out_file"

    joined="${READONLY_MOUNTS[*]}"
    case "$joined" in
        *"$PROJECT_DIR/scripts/deploy.sh:$REMOTE_PATH/scripts/deploy.sh:Z,ro"*)
            pass "existing extra path gets ro mount"
            ;;
        *)
            fail "existing extra path gets ro mount"
            ;;
    esac
    case "$joined" in
        *missing-file*)
            fail "missing extra path gets no mount"
            ;;
        *)
            pass "missing extra path gets no mount"
            ;;
    esac
    if grep -q "missing-file" "$out_file"; then
        pass "missing extra path warns"
    else
        fail "missing extra path warns"
    fi
    rm -f "$out_file"
    rm -rf "$PROJECT_DIR"
}

test_stubs() {
    local out_file

    with_project
    mkdir -p "$PROJECT_DIR/.github/workflows"
    printf 'SECRET=1\n' > "$PROJECT_DIR/.env"

    out_file=$(mktemp)
    ensure_readonly_stubs > "$out_file"

    if [ -d "$PROJECT_DIR/.gitea/workflows" ]; then
        pass "absent workflow dir is stubbed"
    else
        fail "absent workflow dir is stubbed"
    fi
    if grep -q ".gitea/workflows" "$out_file"; then
        pass "stub creation is reported"
    else
        fail "stub creation is reported"
    fi
    if [ "$(cat "$PROJECT_DIR/.env")" = "SECRET=1" ]; then
        pass "existing .env is left untouched"
    else
        fail "existing .env is left untouched"
    fi
    if grep -qE "\.env|\.github" "$out_file"; then
        fail "existing paths are not reported as stubbed"
    else
        pass "existing paths are not reported as stubbed"
    fi

    rm -f "$out_file"
    rm -rf "$PROJECT_DIR"
}

test_stubs_from_empty_project() {
    with_project
    ensure_readonly_stubs > /dev/null

    if [ -d "$PROJECT_DIR/.github/workflows" ] && [ -f "$PROJECT_DIR/.env" ] && [ ! -s "$PROJECT_DIR/.env" ]; then
        pass "empty project gets all stubs, .env empty"
    else
        fail "empty project gets all stubs, .env empty"
    fi

    configure_readonly_paths
    build_readonly_mounts > /dev/null
    case "${READONLY_MOUNTS[*]}" in
        *"$PROJECT_DIR/.github/workflows:$REMOTE_PATH/.github/workflows:Z,ro"*)
            pass "stubbed path receives ro mount"
            ;;
        *)
            fail "stubbed path receives ro mount"
            ;;
    esac

    rm -rf "$PROJECT_DIR"
}

main() {
    test_defaults
    test_readonly_extra
    test_dev_containerfile
    test_mounts
    test_stubs
    test_stubs_from_empty_project

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "readonly paths tests: $PASSED passed"
    else
        echo "readonly paths tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
