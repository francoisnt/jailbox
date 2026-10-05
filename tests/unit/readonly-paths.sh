#!/bin/bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=tests/lib/core.sh
source "$JAILBOX_DIR/tests/lib/core.sh" "$JAILBOX_DIR/src"
REMOTE_PATH=/home/jailbox/project
PASSED=0
FAILED=0
pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }
assert_success() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
assert_failure() { local name="$1"; shift; if ("$@") >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }

# Fixture directories are supplied to code that rejects every symlinked
# component of a trusted input path. macOS places TMPDIR under the symlinked
# /var, so canonicalize unconditionally; tests that need a symlinked spelling
# build one explicitly from the canonical directory.
fixture_dir() {
    local dir

    dir=$(mktemp -d)
    (cd "$dir" && pwd -P)
}
with_project() {
    PROJECT_DIR=$(fixture_dir)
    apply_config_defaults
    PROJECT_RESOURCE_PREFIX="test"
    initialize_dev_image_state
    initialize_container_runtime_state
}
test_validation() {
    local path
    with_project
    mkdir -p "$PROJECT_DIR/docs/api"
    : > "$PROJECT_DIR/Makefile"
    assert_success "regular file accepted" check_readonly_path Makefile
    assert_success "directory accepted" check_readonly_path docs
    for path in "" /etc/passwd . .. ./Makefile docs/../Makefile docs/api/ docs:api missing; do
        assert_failure "invalid path rejected: ${path:-empty}" check_readonly_path "$path"
    done
    assert_failure "empty path component rejected" check_readonly_path docs//api
    ln -s Makefile "$PROJECT_DIR/link"
    ln -s api "$PROJECT_DIR/docs/link"
    assert_failure "leaf symlink rejected" check_readonly_path link
    assert_failure "intermediate symlink rejected" check_readonly_path docs/link/missing
    mkfifo "$PROJECT_DIR/fifo"
    assert_failure "special file rejected" check_readonly_path fifo
    rm -rf "$PROJECT_DIR"
}
test_order_and_mounts() {
    local joined
    with_project
    mkdir -p "$PROJECT_DIR/config" "$PROJECT_DIR/docs"
    : > "$PROJECT_DIR/docs/policy"
    : > "$PROJECT_DIR/jailbox.conf"
    : > "$PROJECT_DIR/config/lane.conf"
    : > "$PROJECT_DIR/Containerfile"
    READONLY_PATHS=(docs/policy jailbox.conf config/lane.conf)
    SELECTED_DEV_CONTAINERFILE_INPUT="$PROJECT_DIR/Containerfile"
    finalize_project_path_policy
    if [ "${EFFECTIVE_READONLY_PATHS[*]}" = "docs/policy jailbox.conf config/lane.conf Containerfile" ]; then
        pass "effective order is composed paths then Containerfile"
    else
        fail "effective order (${EFFECTIVE_READONLY_PATHS[*]})"
    fi
    build_project_mounts
    joined="${PROJECT_MOUNTS[*]}"
    case "$joined" in
        *"$PROJECT_DIR/Containerfile:$REMOTE_PATH/Containerfile:Z,ro"*"$PROJECT_DIR/docs/policy:$REMOTE_PATH/docs/policy:Z,ro"*) pass "effective files get read-only mounts" ;;
        *) fail "effective files get read-only mounts" ;;
    esac
    READONLY_PATHS=(docs)
    build_project_mounts
    case "${PROJECT_MOUNTS[*]}" in *"$PROJECT_DIR/docs:$REMOTE_PATH/docs:Z,ro"*) pass "directory gets read-only mount" ;; *) fail "directory gets read-only mount" ;; esac
    READONLY_PATHS=(docs/policy docs/policy)
    assert_success "duplicate configured path accepted" validate_readonly_paths_lexical
    rm -rf "$PROJECT_DIR"
}
test_anchor_and_empty_regression() {
    local external output_file
    with_project
    external=$(fixture_dir)
    : > "$external/lane.conf"
    : > "$PROJECT_DIR/jailbox.conf"
    SELECTED_DEV_CONTAINERFILE_INPUT=""
    READONLY_PATHS=(jailbox.conf)
    finalize_project_path_policy
    if [ "${EFFECTIVE_READONLY_PATHS[*]-}" = jailbox.conf ]; then pass "external config launch retains default anchor"; else fail "external config launch retains default anchor"; fi
    EFFECTIVE_READONLY_PATHS=()
    output_file=$(mktemp)
    (
        SCRIPT_DIR=$JAILBOX_DIR/src
        validation_ssh() { printf "%s\n" "$*" > "$output_file"; cat >/dev/null; printf 'ok\n'; }
        check_readonly_mounts
    )
    if grep -Eq ' / $' "$output_file"; then pass "empty protected set still validates root mount"; else fail "empty protected set still validates root mount"; fi
    rm -f "$output_file"
    if [ ! -e "$PROJECT_DIR/.env" ] && [ ! -e "$PROJECT_DIR/.github/workflows" ]; then pass "no legacy built-ins or stubs"; else fail "no legacy built-ins or stubs"; fi
    rm -rf "$PROJECT_DIR" "$external"
}
test_recheck() {
    with_project
    : > "$PROJECT_DIR/policy"
    READONLY_PATHS=(policy)
    finalize_project_path_policy
    rm "$PROJECT_DIR/policy"
    ln -s /etc/passwd "$PROJECT_DIR/policy"
    assert_failure "pre-mount recheck rejects symlink replacement" build_project_mounts
    rm -rf "$PROJECT_DIR"
}
test_symlinked_project_root() {
    local project_real project_link
    project_real=$(fixture_dir)
    project_link="${project_real}-link"
    mkdir -p "$project_real/docs"
    : > "$project_real/docs/policy"
    ln -s "$project_real" "$project_link"
    PROJECT_DIR="$project_link"
    if [ "$(check_readonly_path docs/policy)" = docs/policy ]; then pass "symlinked prefix above project root accepted"; else fail "symlinked prefix above project root accepted"; fi
    rm -f "$project_link"
    rm -rf "$project_real"
}
test_directory_symlink_targets() {
    local external original
    with_project
    external=$(fixture_dir)
    mkdir -p "$PROJECT_DIR/policy" "$PROJECT_DIR/targets/nested" "$PROJECT_DIR/chain"
    printf 'protected\n' > "$PROJECT_DIR/target file"
    printf 'transitive\n' > "$PROJECT_DIR/transitive"
    printf 'outside\n' > "$external/file"
    ln -s '../target file' "$PROJECT_DIR/policy/file"
    ln -s ../targets "$PROJECT_DIR/policy/directory"
    ln -s '../../target file' "$PROJECT_DIR/targets/nested/link"
    ln -s ../../transitive "$PROJECT_DIR/targets/nested/transitive"
    ln -s . "$PROJECT_DIR/policy/self"
    ln -s "$external/file" "$PROJECT_DIR/policy/external"
    ln -s '../target file' "$PROJECT_DIR/chain/link"
    ln -s ../chain/link "$PROJECT_DIR/policy/chained"
    READONLY_PATHS=(policy)
    build_project_mounts
    [[ ${EFFECTIVE_READONLY_PATHS[*]} = policy ]] || fail 'contained links changed policy'
    original=${PROJECT_MOUNTS[*]}
    ln -s missing "$PROJECT_DIR/policy/broken"
    ln -s '../target file/' "$PROJECT_DIR/policy/not-directory"
    ln -s cycle "$PROJECT_DIR/policy/cycle"
    ln -s .. "$PROJECT_DIR/policy/root"
    ln -s "$external/missing" "$PROJECT_DIR/policy/external-broken"
    assert_success 'contained broken, cyclic, external and root links accepted' build_project_mounts
    [[ ${PROJECT_MOUNTS[*]} = "$original" ]] || fail 'contained links changed mounts'
    (
        # shellcheck disable=SC2329 # Prove policy resolution never walks directories.
        find() { return 42; }
        build_project_mounts
        [[ ${PROJECT_MOUNTS[*]} = "$original" ]]
    ) || fail 'policy resolution attempted directory discovery'
    pass 'contained links add neither restrictions nor discovery requirements'
    rm -rf "$PROJECT_DIR" "$external"
}
test_containerfile_state() {
    local external external_link output output_file
    with_project
    mkdir -p "$PROJECT_DIR/docker"
    : > "$PROJECT_DIR/docker/dev.Containerfile"
    DEV_CONTAINERFILE=docker/dev.Containerfile
    discover_dev_containerfile
    if [ "$DEV_CONTAINERFILE" = docker/dev.Containerfile ] && [ "$SELECTED_DEV_CONTAINERFILE" = "$PROJECT_DIR/docker/dev.Containerfile" ]; then pass "explicit Containerfile has separate selected state"; else fail "explicit Containerfile has separate selected state"; fi

    DEV_CONTAINERFILE=""
    : > "$PROJECT_DIR/Containerfile"
    initialize_dev_image_state
    discover_dev_containerfile
    if [ "$SELECTED_DEV_CONTAINERFILE" = "$PROJECT_DIR/Containerfile" ]; then pass "implicit Containerfile populates selected state"; else fail "implicit Containerfile populates selected state"; fi
    rm "$PROJECT_DIR/Containerfile"
    ln -s missing-target "$PROJECT_DIR/Containerfile"
    initialize_dev_image_state
    assert_failure "implicit dangling Containerfile symlink rejected" discover_dev_containerfile
    rm "$PROJECT_DIR/Containerfile"

    DEV_CONTAINERFILE=missing.Containerfile
    DEV_IMAGE=""
    output=$( (build_or_select_dev_image) 2>&1 || true)
    case "$output" in *"configured Containerfile does not exist: missing.Containerfile"*) pass "missing explicit Containerfile has path-specific error" ;; *) fail "missing explicit Containerfile has path-specific error" ;; esac
    DEV_CONTAINERFILE=""
    output=$( (build_or_select_dev_image) 2>&1 || true)
    case "$output" in *"no Containerfile found"*) pass "implicit missing Containerfile has discovery guidance" ;; *) fail "implicit missing Containerfile has discovery guidance" ;; esac

    : > "$PROJECT_DIR/Containerfile"
    mkdir "$PROJECT_DIR/context"
    DEV_CONTAINERFILE=Containerfile
    DEV_BUILD_CONTEXT=context
    BUILD_CMD=(caller value)
    podman() { printf '%s\n' "$@" > "$PROJECT_DIR/build-args"; }
    build_or_select_dev_image >/dev/null
    if grep -Fxq "$PROJECT_DIR/Containerfile" "$PROJECT_DIR/build-args" && grep -Fxq "$PROJECT_DIR/context" "$PROJECT_DIR/build-args" && [[ "${BUILD_CMD[*]}" == 'caller value' ]]; then
        pass "build uses classified inputs and preserves caller variables"
    else
        fail "build arguments or caller variables changed"
    fi
    ln -s context "$PROJECT_DIR/context-link"
    DEV_BUILD_CONTEXT=context-link
    assert_failure "symlinked build context rejected" build_or_select_dev_image

    external=$(fixture_dir)
    external_link="${external}-link"
    : > "$external/Containerfile"
    ln -s "$external" "$external_link"
    DEV_BUILD_CONTEXT=""
    DEV_CONTAINERFILE="$external_link/Containerfile"
    initialize_dev_image_state
    assert_failure "external Containerfile through symlinked prefix rejected" discover_dev_containerfile
    DEV_CONTAINERFILE="$external/Containerfile"
    initialize_dev_image_state
    assert_success "external Containerfile through physical path accepted" discover_dev_containerfile

    DEV_IMAGE=example.invalid/dev:latest
    DEV_CONTAINERFILE=missing
    SELECTED_DEV_CONTAINERFILE=stale
    SELECTED_DEV_CONTAINERFILE_INPUT=stale
    output_file=$(mktemp)
    build_or_select_dev_image > "$output_file"
    if [ "$PROJECT_DEV_IMAGE" = "$DEV_IMAGE" ] && [ -z "$SELECTED_DEV_CONTAINERFILE" ] && [ -z "$SELECTED_DEV_CONTAINERFILE_INPUT" ] && [ -z "$SELECTED_DEV_BUILD_CONTEXT" ]; then pass "DEV_IMAGE bypasses Containerfile selection"; else fail "DEV_IMAGE bypasses Containerfile selection ($(cat "$output_file"))"; fi
    : > "$PROJECT_DIR/unreadable.Containerfile"
    chmod 000 "$PROJECT_DIR/unreadable.Containerfile"
    for DEV_CONTAINERFILE in context context-link missing unreadable.Containerfile; do
        assert_success "DEV_IMAGE bypasses invalid Containerfile: $DEV_CONTAINERFILE" build_or_select_dev_image
    done
    rm -f "$output_file"
    rm -f "$external_link"
    rm -rf "$PROJECT_DIR" "$external"
}
main() {
    test_validation
    test_order_and_mounts
    test_anchor_and_empty_regression
    test_recheck
    test_symlinked_project_root
    test_directory_symlink_targets
    test_containerfile_state
    echo ""
    if [ "$FAILED" -eq 0 ]; then echo "readonly paths tests: $PASSED passed"; else echo "readonly paths tests: $PASSED passed, $FAILED failed"; exit 1; fi
}
main "$@"
