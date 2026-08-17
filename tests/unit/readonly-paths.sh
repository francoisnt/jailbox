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
    CONFIG_FILE=""
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
    mkdir -p "$PROJECT_DIR/docker"
    touch "$PROJECT_DIR/docker/dev.Dockerfile"
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
    mkdir -p "$PROJECT_DIR/docker"
    touch "$PROJECT_DIR/docker/dev.Dockerfile"
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

# macOS temporary directories are commonly reported below /var even though
# realpath resolves them below /private/var. A symlinked fixture reproduces that
# lexical-vs-physical path mismatch on every OS and guards the containment check.
test_dev_containerfile_with_symlinked_project() {
    local project_real project_link

    project_real=$(mktemp -d)
    project_link="${project_real}-link"
    ln -s "$project_real" "$project_link"
    PROJECT_DIR="$project_link"
    apply_config_defaults
    mkdir -p "$PROJECT_DIR/docker"
    touch "$PROJECT_DIR/docker/dev.Dockerfile"

    DEV_CONTAINERFILE="docker/dev.Dockerfile"
    configure_readonly_paths
    assert_listed_once "custom containerfile listed through canonicalized project path" "docker/dev.Dockerfile"

    rm -f "$project_link"
    rm -rf "$project_real"
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

    joined="${READONLY_MOUNTS[*]-}"
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
    case "${READONLY_MOUNTS[*]-}" in
        *"$PROJECT_DIR/.github/workflows:$REMOTE_PATH/.github/workflows:Z,ro"*)
            pass "stubbed path receives ro mount"
            ;;
        *)
            fail "stubbed path receives ro mount"
            ;;
    esac

    rm -rf "$PROJECT_DIR"
}

test_selected_config_readonly_paths() {
    local external

    with_project
    external=$(mktemp -d)
    mkdir -p "$PROJECT_DIR/config"
    touch "$PROJECT_DIR/config/lane.conf" "$PROJECT_DIR/config/target.conf"
    CONFIG_FILE="$PROJECT_DIR/config/lane.conf"
    READONLY_EXTRA=(config/lane.conf)
    configure_readonly_paths

    assert_listed_once "selected config deduplicates with readonly extra" "config/lane.conf"

    build_readonly_mounts > /dev/null
    case "${READONLY_MOUNTS[*]-}" in
        *"$PROJECT_DIR/config/lane.conf:$REMOTE_PATH/config/lane.conf:Z,ro"*)
            pass "selected in-project config receives ro mount"
            ;;
        *)
            fail "selected in-project config receives ro mount"
            ;;
    esac

    initialize_container_runtime_state
    apply_config_defaults
    CONFIG_FILE="$external/lane.conf"
    touch "$CONFIG_FILE"
    configure_readonly_paths
    build_readonly_mounts > /dev/null
    case "${READONLY_MOUNTS[*]-}" in
        *"$external/lane.conf"*) fail "external config receives no project mount" ;;
        *) pass "external config receives no project mount" ;;
    esac

    initialize_container_runtime_state
    apply_config_defaults
    ln -s target.conf "$PROJECT_DIR/config/link.conf"
    CONFIG_FILE=$(realpath "$PROJECT_DIR/config/link.conf")
    configure_readonly_paths
    assert_listed_once "canonical symlink target is protected" "config/target.conf"

    initialize_container_runtime_state
    apply_config_defaults
    touch "$PROJECT_DIR/jailbox.conf"
    CONFIG_FILE="$PROJECT_DIR/jailbox.conf"
    configure_readonly_paths
    assert_listed_once "default config remains deduplicated" "jailbox.conf"

    rm -rf "$PROJECT_DIR" "$external"
}

test_canonical_project_relative_path() {
    local sibling

    with_project
    mkdir -p "$PROJECT_DIR/config"
    touch "$PROJECT_DIR/config/lane.conf"
    sibling="${PROJECT_DIR}-sibling"
    mkdir "$sibling"
    touch "$sibling/lane.conf"

    if [ "$(canonical_project_relative_path "$PROJECT_DIR/config/lane.conf")" = "config/lane.conf" ]; then
        pass "canonical containment returns project-relative path"
    else
        fail "canonical containment returns project-relative path"
    fi
    if canonical_project_relative_path "$sibling/lane.conf" >/dev/null 2>&1; then
        fail "canonical containment rejects sibling prefix"
    else
        pass "canonical containment rejects sibling prefix"
    fi
    if canonical_project_relative_path "$PROJECT_DIR/missing.conf" >/dev/null 2>&1; then
        fail "canonical containment rejects missing path"
    else
        pass "canonical containment rejects missing path"
    fi

    rm -rf "$PROJECT_DIR" "$sibling"
}

test_external_config_project_relative_setting() {
    local external

    with_project
    external=$(mktemp -d)
    mkdir -p "$PROJECT_DIR/config"
    touch "$PROJECT_DIR/config/project-only.txt"
    printf 'READONLY_EXTRA=config/project-only.txt\n' > "$external/lane.conf"

    CONFIG_PATH_ARG="$external/lane.conf"
    prepare_config_selection
    load_project_config
    configure_readonly_paths
    build_readonly_mounts > /dev/null

    case "${READONLY_MOUNTS[*]-}" in
        *"$PROJECT_DIR/config/project-only.txt:$REMOTE_PATH/config/project-only.txt:Z,ro"*)
            pass "external config relative setting resolves from project"
            ;;
        *)
            fail "external config relative setting resolves from project"
            ;;
    esac

    rm -rf "$PROJECT_DIR" "$external"
}

main() {
    test_defaults
    test_readonly_extra
    test_dev_containerfile
    test_dev_containerfile_with_symlinked_project
    test_mounts
    test_stubs
    test_stubs_from_empty_project
    test_selected_config_readonly_paths
    test_canonical_project_relative_path
    test_external_config_project_relative_setting

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "readonly paths tests: $PASSED passed"
    else
        echo "readonly paths tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
