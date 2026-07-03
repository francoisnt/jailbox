#!/bin/bash
# Integration test runner for jailbox.
#
# For each stage in tests/integration/dev-images.Containerfile, in parallel:
#   1. Build the stage as a dev image
#   2. Build container/Containerfile.wrapper against it
#   3. Start the container with SSH
#   4. Run assertions
#   5. Tear down
#
# Each stage gets its own SSH port so all stages can run simultaneously.
# Output is buffered per stage and printed in order once all finish.
#
# Usage: tests/integration/wrapper-images.sh [stage...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ALL_STAGES=(debian alpine fedora uid-owned-by-other-user user-conflict)

PASSED=0
FAILED=0

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

Run jailbox integration tests. With no arguments all stages run in parallel.

Stages: ${ALL_STAGES[*]}

Requires: podman, ssh, ssh-keygen, cksum
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

stage_forward_port() {
    case "$1" in
        debian)       echo 23229 ;;
        alpine)       echo 23230 ;;
        fedora)       echo 23231 ;;
        uid-owned-by-other-user) echo 23232 ;;
        user-conflict)           echo 23233 ;;
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
    StrictHostKeyChecking no
    UserKnownHostsFile $ssh_dir/known_hosts
    BatchMode yes
EOF
    chmod 600 "$ssh_dir/config"
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


assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

assert_local_forwarding() {
    local config="$1" port="$2" desc="$3"
    local forward_pid=""

    ssh -F "$config" -N -L "127.0.0.1:${port}:127.0.0.1:2222" jailbox-test >/dev/null 2>&1 &
    forward_pid=$!

    for _ in $(seq 1 20); do
        if timeout 1 bash -c \
            "exec 3<>/dev/tcp/127.0.0.1/$port; IFS= read -r line <&3; [[ \$line == SSH-* ]]" \
            2>/dev/null; then
            kill "$forward_pid" >/dev/null 2>&1 || true
            wait "$forward_pid" 2>/dev/null || true
            pass "$desc"
            return 0
        fi
        sleep 0.1
    done

    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" 2>/dev/null || true
    echo "  Forwarding diagnostic:"
    ssh -vv -F "$config" -o ConnectTimeout=3 -N \
        -L "127.0.0.1:${port}:127.0.0.1:2222" jailbox-test 2>&1 \
        | sed 's/^/    /' &
    forward_pid=$!
    sleep 1
    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" 2>/dev/null || true
    fail "$desc"
}

# ── run_case ──────────────────────────────────────────────────────────────────
# Designed to run inside a subshell. PASSED/FAILED are subshell-local;
# written to $log_dir/$stage.counts at exit for the parent to collect.

run_case() {
    local stage="$1"
    local log_dir="$2"
    local port forward_port test_build_args ctr expect_wrapper_failure
    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope. Initialize here so the trap can
    # always reference them safely under set -u.
    ssh_dir=""
    home_dir=""
    sshd_runtime_dir=""
    project_dir=""
    build_log=""

    port=$(stage_port "$stage")
    forward_port=$(stage_forward_port "$stage")
    test_build_args=()
    expect_wrapper_failure=false

    case "$stage" in
        uid-owned-by-other-user)
            test_build_args=(--build-arg "HOST_UID=$(id -u)")
            expect_wrapper_failure=true
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
    trap 'echo "$PASSED $FAILED" > "'"$log_dir"'/'"$stage"'.counts"
          rm -rf "$ssh_dir"
          rm -rf "$home_dir"
          rm -rf "$sshd_runtime_dir"
          rm -rf "$project_dir"
          podman stop "'"$ctr"'" >/dev/null 2>&1 || true
          podman rm   "'"$ctr"'" >/dev/null 2>&1 || true' EXIT

    echo ""
    echo "── $stage (user: jailbox, port: $port) ──────────────────────────────"

    podman stop "$ctr" 2>/dev/null || true
    podman rm   "$ctr" 2>/dev/null || true

    # Build test dev image
    if ! podman build \
            --target "$stage" \
            "${test_build_args[@]}" \
            -t "$test_image" \
            -f "$JAILBOX_DIR/tests/integration/dev-images.Containerfile" \
            "$JAILBOX_DIR" > "$build_log" 2>&1; then
        fail "test image build"
        tail -20 "$build_log" >&2
        return 1
    fi

    # Build jailbox wrapper
    if ! podman build \
            -t "$wrapper_image" \
            -f "$JAILBOX_DIR/container/Containerfile.wrapper" \
            --build-arg "DEV_IMAGE=${test_image}" \
            --build-arg "JAILBOX_INSTALL_CACHE_BUST=$(jailbox_install_cache_bust)" \
            --build-arg "USER_ID=$(id -u)" \
            "$JAILBOX_DIR/container" > "$build_log" 2>&1; then
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

    assert_probe_hardening "$test_image"

    setup_ssh_keys "$ssh_dir" "$port"
    assert_bad_runtime_dir_fails "$wrapper_image" "$ssh_dir" "$ctr" "bad sshd runtime directory fails clearly before sshd"

    # Project fixture for assert_readonly_mount_validation: Containerfile,
    # .git/hooks, and .jailbox get read-only overlays below; Dockerfile and
    # .github/workflows are deliberately listed as protected but left writable.
    # The read-only .jailbox mount mirrors production and pins the old vacuous
    # marker-in-.jailbox implementation as a failure.
    project_dir=$(mktemp -d)
    mkdir -p "$project_dir/.git/hooks" "$project_dir/.github/workflows" "$project_dir/.jailbox"
    printf 'FROM scratch\n' > "$project_dir/Containerfile"
    printf 'FROM scratch\n' > "$project_dir/Dockerfile"

    # Mirror production's /run/jailbox-sshd bind mount. A plain tmpfs at that
    # path is root-owned under Podman, while a world-writable /run breaks
    # OpenSSH StrictModes for AuthorizedKeysFile.
    # The public key is mounted as a source file and copied by container/entrypoint.sh,
    # matching production's generated runtime auth state.
    if ! podman run -d \
        --name "$ctr" \
        --replace \
        --userns=keep-id \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --tmpfs /run:rw,size=64m \
        -p "127.0.0.1:${port}:2222" \
        -v "${home_dir}:/home/jailbox:Z" \
        -v "${sshd_runtime_dir}:/run/jailbox-sshd:Z" \
        -v "${ssh_dir}/key.pub:/etc/ssh/jailbox_authorized_keys.source:ro,Z" \
        -v "${project_dir}:/home/jailbox/project:Z" \
        -v "${project_dir}/Containerfile:/home/jailbox/project/Containerfile:Z,ro" \
        -v "${project_dir}/.git/hooks:/home/jailbox/project/.git/hooks:Z,ro" \
        -v "${project_dir}/.jailbox:/home/jailbox/project/.jailbox:Z,ro" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$wrapper_image" >/dev/null; then
        fail "container starts"
        return 1
    fi

    if ! wait_for_ssh "$ssh_dir/config"; then
        fail "SSH ready"
        podman logs "$ctr" >&2 || true
        return 1
    fi

    pass "SSH ready"

    assert_eq "whoami is jailbox"      "jailbox" "$(ssh_run "$ssh_dir/config" whoami 2>/dev/null || true)"
    assert_eq "UID matches host"       "$(id -u)"  "$(ssh_run "$ssh_dir/config" id -u 2>/dev/null || true)"
    assert_runtime_dir_valid "$ssh_dir/config" "sshd runtime directory is writable, private, and owned by runtime UID"
    assert_ssh "$ssh_dir/config" "home dir exists"  "test -d /home/jailbox"
    assert_rootfs_read_only "$ssh_dir/config" "rootfs is read-only"
    assert_host_container_sockets_absent "$ssh_dir/config"
    assert_zero_effective_capabilities "$ssh_dir/config"
    assert_local_forwarding "$ssh_dir/config" "$forward_port" "SSH local forwarding works"
    # Last: mutates READONLY_PATHS and other host-module globals (safe in this
    # per-stage subshell, but keep it after the plain container assertions).
    assert_readonly_mount_validation "$ssh_dir/config" "$project_dir"
}

jailbox_install_cache_bust() {
    find "$JAILBOX_DIR/container" -type f -print0 \
        | sort -z \
        | xargs -0 cksum \
        | cksum \
        | cut -d' ' -f1
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage; exit 0
    fi

    command -v podman     >/dev/null 2>&1 || die "podman is required"
    command -v ssh        >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
    command -v cksum      >/dev/null 2>&1 || die "cksum is required"

    local stages=("$@")
    [ ${#stages[@]} -eq 0 ] && stages=("${ALL_STAGES[@]}")

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do [ "$s" = "$a" ] && valid=1 && break; done
        [ $valid -eq 1 ] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
    done

    local log_dir
    log_dir="$JAILBOX_DIR/testlog/test-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$log_dir"

    echo "jailbox integration tests (parallel)"
    echo "Stages : ${stages[*]}"
    echo ""

    # Launch all stages in parallel; each subshell buffers its own output.
    local -A stage_pids=()
    for stage in "${stages[@]}"; do
        printf "  ⏳ %s\n" "$stage"
        ( run_case "$stage" "$log_dir" ) > "$log_dir/${stage}.log" 2>&1 &
        stage_pids[$stage]=$!
    done
    echo ""

    # Poll every 300ms; print a result line as each stage finishes.
    # Completion is signalled by the EXIT trap writing $stage.counts.
    local -A reported=()
    local last_progress
    last_progress=$SECONDS
    while [[ ${#reported[@]} -lt ${#stages[@]} ]]; do
        for stage in "${stages[@]}"; do
            [[ "${reported[$stage]+_}" ]] && continue
            local p=0 f=0
            if [[ -f "$log_dir/${stage}.counts" ]]; then
                read -r p f < "$log_dir/${stage}.counts" || true
                if [[ "$f" -eq 0 ]]; then
                    printf "  ✅ %-16s (%d passed)\n" "$stage" "$p"
                else
                    printf "  ❌ %-16s (%d passed, %d failed)\n" "$stage" "$p" "$f"
                    sed 's/^/      /' "$log_dir/${stage}.log" 2>/dev/null || true
                fi
                reported[$stage]=1
            elif ! kill -0 "${stage_pids[$stage]}" 2>/dev/null; then
                # Process exited without writing counts (early crash).
                printf "  ❌ %-16s (crashed)\n" "$stage"
                sed 's/^/      /' "$log_dir/${stage}.log" 2>/dev/null || true
                reported[$stage]=1
            fi
        done
        if [[ ${#reported[@]} -lt ${#stages[@]} && $((SECONDS - last_progress)) -ge 30 ]]; then
            printf "  … still running:"
            for stage in "${stages[@]}"; do
                [[ "${reported[$stage]+_}" ]] || printf " %s" "$stage"
            done
            printf "\n"
            last_progress=$SECONDS
        fi
        [[ ${#reported[@]} -lt ${#stages[@]} ]] && sleep 0.3
    done
    echo ""

    # Reap all background jobs.
    for pid in "${stage_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Print full per-stage output in defined order and keep the same files in
    # testlog for terminals that clip long runs.
    local total_passed=0 total_failed=0 p f
    for stage in "${stages[@]}"; do
        cat "$log_dir/${stage}.log" 2>/dev/null || true
        if [[ -f "$log_dir/${stage}.counts" ]]; then
            read -r p f < "$log_dir/${stage}.counts"
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
        else
            total_failed=$((total_failed + 1))
        fi
    done

    echo ""
    echo "──────────────────────────────────────────────────────────────────────"
    echo "Results: $total_passed passed, $total_failed failed"
    echo "Full logs: $log_dir"
    [ $total_failed -eq 0 ] || exit 1
}

main "$@"
