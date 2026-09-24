#!/bin/bash
# Integration test runner for jailbox.
#
# For each stage in tests/integration/dev-images.Containerfile:
#   1. Build the stage as a dev image
#   2. Build container/Containerfile.wrapper against it
#   3. Start the container with SSH
#   4. Run assertions
#   5. Tear down
#
# Stages use distinct SSH ports and a resource-sized worker pool.
# Full output is saved per stage; failures are also printed to the terminal.
#
# Usage: tests/integration/wrapper-images.sh [--prepare-only] [stage...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
if [[ ${BASH_SOURCE[0]} = "$0" ]]; then
    test_log_entrypoint "$SCRIPT_DIR/${BASH_SOURCE[0]##*/}" "$@"
fi

ALL_STAGES=(debian alpine fedora uid-owned-by-other-user user-conflict)
PREPARATION_STAGES=(debian alpine fedora)
PREPARE_ONLY=false

PASSED=0
FAILED=0

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

usage() {
    cat <<EOF
Usage: $(basename "$0") [--prepare-only] [stage...]

Run jailbox integration tests. With no arguments stages run with resource-based concurrency limits.
With --prepare-only, build positive-stage images without contract assertions.

Stages: ${ALL_STAGES[*]}

Requires: podman and cksum; full contract validation also requires ssh and
ssh-keygen.
EOF
}

# Each stage gets a fixed dedicated port to allow parallel container runs.
stage_port() {
    case "$1" in
        debian)       echo 22229 ;;
        alpine)       echo 22230 ;;
        fedora)       echo 22231 ;;
        uid-owned-by-other-user) echo 22232 ;;
        user-conflict)           echo 22233 ;;
        *) die "unknown stage: $1" ;;
    esac
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

setup_ssh_keys() {
    local ssh_dir="$1" port="$2"
    local key="$ssh_dir/key"
    rm -f "$key" "$key.pub"
    ssh-keygen -t ed25519 -f "$key" -N "" -q
    chmod 600 "$key"
    chmod 644 "$key.pub"
    : > "$ssh_dir/known_hosts"
    chmod 600 "$ssh_dir/known_hosts"
    cat > "$ssh_dir/config" <<EOF
Host jailbox-test
    HostName localhost
    Port $port
    User jailbox
    IdentityFile $key
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile $ssh_dir/known_hosts
    GlobalKnownHostsFile /dev/null
    UpdateHostKeys no
    BatchMode yes
EOF
    chmod 600 "$ssh_dir/config"
}

prepare_server_keys() {
    local ssh_dir="$1" port="$2" runtime_dir="$3"
    ssh-keygen -t ed25519 -f "$runtime_dir/ssh_host_ed25519_key" -N "" -q
    cp "$ssh_dir/key.pub" "$runtime_dir/authorized_keys"
    chmod 600 "$runtime_dir/authorized_keys" "$runtime_dir/ssh_host_ed25519_key"
    printf "[localhost]:%s %s\n" "$port" "$(cat "$runtime_dir/ssh_host_ed25519_key.pub")" > "$ssh_dir/known_hosts"
}

ssh_run() {
    local config="$1"; shift
    ssh -F "$config" -o ConnectTimeout=3 jailbox-test "$@"
}

wait_for_ssh() {
    local config="$1"
    for _ in $(seq 1 30); do
        if ssh_run "$config" true 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

assert_ssh() {
    local config="$1" desc="$2"; shift 2
    if ssh_run "$config" "$@" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# shellcheck source=tests/integration/runtime-security.sh
source "$SCRIPT_DIR/runtime-security.sh"

# shellcheck source=versions.env
source "$JAILBOX_DIR/versions.env"

# shellcheck source=tests/lib/run-meta.sh
source "$JAILBOX_DIR/tests/lib/run-meta.sh"


assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

# ── run_case ──────────────────────────────────────────────────────────────────
# Designed to run inside a subshell. PASSED/FAILED are subshell-local;
# written to $log_dir/$stage.counts at exit for the parent to collect.

cleanup_wrapper_stage() {
    local status=$?
    test_phase_end "$status" || true
    test_phase_begin cleanup || true
    echo "$PASSED $FAILED" > "$stage_counts_file"
    rm -rf "$ssh_dir"
    rm -rf "$home_dir"
    rm -rf "$sshd_runtime_dir"
    rm -rf "$project_dir"
    rm -rf "$build_context"
    podman stop "$ctr" >/dev/null 2>&1 || true
    podman rm "$ctr" >/dev/null 2>&1 || true
    test_phase_end "$status" || true
}

run_case() {
    local stage="$1"
    local log_dir="$2"
    local port test_build_args expect_wrapper_failure test_image_id wrapper_context install_cache_bust managed_id existing_user
    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope. Initialize here so the trap can
    # always reference them safely under set -u.
    ssh_dir=""
    home_dir=""
    sshd_runtime_dir=""
    project_dir=""
    build_log=""
    build_context=""

    port=$(stage_port "$stage")
    test_build_args=()
    expect_wrapper_failure=false

    case "$stage" in
        uid-owned-by-other-user)
            test_build_args=(--build-arg "HOST_UID=$(id -u)")
            ;;
        user-conflict)
            expect_wrapper_failure=true
            ;;
    esac

    local test_image="jailbox-test-${stage}"
    local wrapper_image="jailbox-wrapper-${stage}"
    ctr="jailbox-test-${stage}-ctr"
    ssh_dir=$(mktemp -d)
    home_dir=$(mktemp -d)
    sshd_runtime_dir=$(mktemp -d)
    build_log="$log_dir/${stage}.build.log"

    # Fires when the subshell exits — cleans up regardless of success/failure.
    stage_counts_file="$log_dir/$stage.counts"
    trap cleanup_wrapper_stage EXIT

    echo ""
    echo "── $stage (user: jailbox, port: $port) ──────────────────────────────"

    podman stop "$ctr" 2>/dev/null || true
    podman rm   "$ctr" 2>/dev/null || true

    test_phase_begin dev-image-build || return 1
    # Build test dev image
    if ! test_log_capture "$build_log" podman build \
            --target "$stage" \
            "${test_build_args[@]}" \
            --build-arg "BASE_IMAGE_DEBIAN=${BASE_IMAGE_DEBIAN}" \
            --build-arg "BASE_IMAGE_ALPINE=${BASE_IMAGE_ALPINE}" \
            --build-arg "BASE_IMAGE_FEDORA=${BASE_IMAGE_FEDORA}" \
            -t "$test_image" \
            -f "$JAILBOX_DIR/tests/integration/dev-images.Containerfile" \
            "$JAILBOX_DIR"; then
        fail "test image build"
        tail -20 "$build_log" >&2
        return 1
    fi

    # Match the CLI's immutable FROM input so subsequent launches share the
    # prepared wrapper layers instead of repeating package installation.
    if ! test_image_id=$(podman image inspect "$test_image" --format '{{.Id}}'); then
        fail "test image identity inspection"
        return 1
    fi
    # Model runtime inputs copied by a restrictive installer. Startup and the
    # unprivileged runtime checks must still be able to read installed helpers.
    wrapper_context="$JAILBOX_DIR/src/container"
    if [[ "$stage" = debian && "$PREPARE_ONLY" = false ]]; then
        build_context=$(mktemp -d) || return 1
        cp -R "$JAILBOX_DIR/src/container/." "$build_context/" || return 1
        find "$build_context/runtime" -type d -exec chmod 0700 {} + || return 1
        find "$build_context/runtime" -type f -exec chmod 0600 {} + || return 1
        wrapper_context="$build_context"
    fi
    test_phase_begin wrapper-image-build || return 1
    # Build jailbox wrapper
    install_cache_bust=$(wrapper_install_cache_bust) || return 1
    if ! test_log_capture "$build_log" podman build \
            -t "$wrapper_image" \
            -f "$JAILBOX_DIR/src/container/Containerfile.wrapper" \
            --pull=never \
            --build-arg "DEV_IMAGE=${test_image_id}" \
            --build-arg "JAILBOX_INSTALL_CACHE_BUST=$install_cache_bust" \
            --build-arg "USER_ID=$(id -u)" \
            "$wrapper_context"; then
        if [ "$expect_wrapper_failure" = true ] && grep -Eq "already exists in the dev image|already belongs to existing image user" "$build_log"; then
            pass "wrapper image build rejects unsafe user conflict"
            return 0
        fi
        fail "wrapper image build"
        tail -20 "$build_log" >&2
        return 1
    fi
    if [ "$expect_wrapper_failure" = true ]; then
        fail "wrapper image build should reject managed user UID conflict"
        return 1
    fi

    pass "images build"

    # Editor tests consume the positive test and wrapper images but do not own
    # the editor-independent security contract. Runtime continues below and
    # performs every wrapper/container assertion.
    [ "$PREPARE_ONLY" = false ] || return 0

    managed_id=$(podman run --rm --network=none --cap-drop=ALL --security-opt=no-new-privileges \
        --read-only --entrypoint id "$wrapper_image" -u jailbox) || return 1
    [[ "$managed_id" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    test_phase_begin container-contract || return 1
    assert_probe_hardening "$test_image"

    setup_ssh_keys "$ssh_dir" "$port"
    prepare_server_keys "$ssh_dir" "$port" "$sshd_runtime_dir"
    assert_bad_runtime_dir_fails "$wrapper_image" "$ssh_dir" "$ctr" "bad sshd runtime directory fails clearly before sshd"

    # Project fixture for assert_readonly_mount_validation: Containerfile and
    # .git/hooks get read-only overlays below; Dockerfile and .github/workflows
    # are deliberately listed as protected but left writable.
    project_dir=$(mktemp -d)
    mkdir -p "$project_dir/.git/hooks" "$project_dir/.github/workflows"
    printf 'FROM scratch\n' > "$project_dir/Containerfile"
    printf 'FROM scratch\n' > "$project_dir/Dockerfile"

    # Mirror production: immutable authentication and separate writable daemon state.
    if ! podman run -d \
        --name "$ctr" \
        --replace \
        --userns="keep-id:uid=$managed_id,gid=$managed_id" \
        --user "$managed_id:$managed_id" \
        --env JAILBOX_SSH_PROXY_URL= \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --mount type=tmpfs,destination=/run,tmpfs-size=64m,tmpfs-mode=0700,U=true \
        -p "127.0.0.1:${port}:2222" \
        -v "${home_dir}:/home/jailbox:Z" \
        -v "${sshd_runtime_dir}:/run/jailbox-sshd:ro,Z" \
        -v "${project_dir}:/home/jailbox/project:Z" \
        -v "${project_dir}/Containerfile:/home/jailbox/project/Containerfile:Z,ro" \
        -v "${project_dir}/.git/hooks:/home/jailbox/project/.git/hooks:Z,ro" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$wrapper_image" >/dev/null; then
        fail "container starts"
        return 1
    fi

    pass "SSH host key pinned before creation"

    if ! wait_for_ssh "$ssh_dir/config"; then
        fail "SSH ready"
        podman logs "$ctr" >&2 || true
        return 1
    fi

    pass "SSH ready"
    assert_generation_restart "$ctr" "$ssh_dir/config" "$ssh_dir" "$sshd_runtime_dir"

    assert_eq "whoami is jailbox"      "jailbox" "$(ssh_run "$ssh_dir/config" whoami 2>/dev/null || true)"
    assert_eq "UID matches managed image account" "$managed_id"  "$(ssh_run "$ssh_dir/config" id -u 2>/dev/null || true)"
    if [[ "$stage" = uid-owned-by-other-user ]]; then
        existing_user=appuser
        [[ $(id -u) != 1000 ]] || existing_user=node
        assert_eq 'existing image user is unchanged' "$(id -u)" "$(ssh_run "$ssh_dir/config" id -u "$existing_user")"
        assert_eq 'Node image retains its original account' 1000 "$(ssh_run "$ssh_dir/config" id -u node)"
        assert_ssh "$ssh_dir/config" 'Node quick-start runtime is available' 'node --version'
        if [[ "$managed_id" != "$(id -u)" ]]; then
            pass 'collision selects another UID'
        else
            fail 'collision selects another UID'
        fi
    fi
    assert_ssh "$ssh_dir/config" 'mapped user can create project files' 'touch /home/jailbox/project/owner-check'
    assert_eq 'new project files belong to host user' "$(id -u):$(id -g)" "$(stat -c '%u:%g' "$project_dir/owner-check")"
    assert_runtime_dir_valid "$ssh_dir/config" "authentication mount is read-only, private, and owned by runtime UID"
    assert_ssh "$ssh_dir/config" "home dir exists"  "test -d /home/jailbox"
    assert_rootfs_read_only "$ssh_dir/config" "rootfs is read-only"
    assert_host_container_sockets_absent "$ssh_dir/config"
    assert_zero_effective_capabilities "$ssh_dir/config"
    if assert_ssh_forwarding_disabled "$ssh_dir/config" "$ctr"; then
        pass 'server denies requested agent forwarding and disables X11 forwarding'
    else
        fail 'SSH forwarding policy'
    fi
    # Last: mutates effective read-only and other host-module globals (safe in this
    # per-stage subshell, but keep it after the plain container assertions).
    assert_readonly_mount_validation "$ssh_dir/config" "$project_dir"

    # Keep the normal-input wrapper tagged through project cleanup. Debian's
    # restrictive-input build above remains the one used for contract checks.
    if [[ "$stage" = debian ]]; then
        test_phase_begin canonical-wrapper-cache || return 1
        if ! test_log_capture "$log_dir/$stage.canonical-build.log" podman build \
            -t "$wrapper_image" -f "$JAILBOX_DIR/src/container/Containerfile.wrapper" \
            --pull=never --build-arg "DEV_IMAGE=$test_image_id" \
            --build-arg "JAILBOX_INSTALL_CACHE_BUST=$install_cache_bust" \
            --build-arg "USER_ID=$(id -u)" "$JAILBOX_DIR/src/container"; then
            fail 'canonical wrapper cache preparation'
            tail -20 "$log_dir/$stage.canonical-build.log" >&2
            return 1
        fi
    fi
}

wrapper_install_cache_bust() (
    # Preparation and the CLI must identify the same wrapper build inputs.
    SCRIPT_DIR=$JAILBOX_DIR/src
    # shellcheck source=src/host/core/resources/images.sh
    source "$JAILBOX_DIR/src/host/core/resources/images.sh"
    jailbox_install_cache_bust
)

# shellcheck source=tests/lib/stage-pool.sh
source "$JAILBOX_DIR/tests/lib/stage-pool.sh"
STAGE_WORKER_VARIABLES="PREPARE_ONLY"

# ── main ──────────────────────────────────────────────────────────────────────

# The coordinator joins workers before releasing anything they may still use.
cleanup_wrapper_pool() {
    local status=$?
    trap - EXIT
    trap '' INT TERM HUP
    stage_pool_cancel || { ((status != 0)) || status=1; }
    test_progress_complete
    exit "$status"
}

main() {
    trap cleanup_wrapper_pool EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage; exit 0
    fi
    if [[ "${1:-}" == "--prepare-only" ]]; then
        PREPARE_ONLY=true
        shift
    fi

    command -v podman >/dev/null 2>&1 || die "podman is required"
    command -v cksum  >/dev/null 2>&1 || die "cksum is required"
    if [ "$PREPARE_ONLY" = false ]; then
        command -v ssh        >/dev/null 2>&1 || die "ssh is required"
        command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
    fi

    local stages=("$@")
    if [ -z "${stages[*]-}" ]; then
        if [ "$PREPARE_ONLY" = true ]; then
            stages=("${PREPARATION_STAGES[@]}")
        else
            stages=("${ALL_STAGES[@]}")
        fi
    fi

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do [ "$s" = "$a" ] && valid=1 && break; done
        [ $valid -eq 1 ] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
        if [ "$PREPARE_ONLY" = true ]; then
            case "$s" in
                uid-owned-by-other-user|user-conflict)
                    die "--prepare-only accepts shared preparation stages only: ${PREPARATION_STAGES[*]}"
                    ;;
            esac
        fi
    done

    local log_dir
    log_dir="$JAILBOX_DIR/testlog/test-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$log_dir"
    write_run_meta "$log_dir"

    if [ "$PREPARE_ONLY" = true ]; then
        echo "jailbox wrapper image preparation (parallel)"
    else
        echo "jailbox integration tests (parallel)"
    fi
    echo "Stages : ${stages[*]}"
    echo ""

    local pool_result=0
    run_stage_pool runtime "${JAILBOX_TEST_GATE:-runtime}/wrapper" "$log_dir" run_case "${BASH_SOURCE[0]}" "${stages[@]}" || pool_result=1

    # Record only base images selected for this run. In particular, VS Code
    # preparation omits Alpine and must not pull it merely for metadata.
    local base_stage base_ref
    for base_stage in debian alpine fedora; do
        case " ${stages[*]} " in
            *" $base_stage "*) ;;
            *) continue ;;
        esac
        case "$base_stage" in
            debian) base_ref="$BASE_IMAGE_DEBIAN" ;;
            alpine) base_ref="$BASE_IMAGE_ALPINE" ;;
            fedora) base_ref="$BASE_IMAGE_FEDORA" ;;
        esac
        run_meta_image "$log_dir" "$base_stage" "$base_ref"
    done

    echo ""
    echo "──────────────────────────────────────────────────────────────────────"
    echo "Results: $STAGE_PASSED passed, $STAGE_FAILED failed"
    echo "Full logs: $(run_log_path "$log_dir")"
    [[ $STAGE_FAILED -eq 0 && $pool_result -eq 0 ]] || exit 1
}

if [[ ${BASH_SOURCE[0]} = "$0" ]]; then main "$@"; fi
