#!/bin/bash
# Integration test runner for jailbox.
#
# For each stage in Containerfile.test, in parallel:
#   1. Build the stage as a dev image
#   2. Build Containerfile.wrapper against it
#   3. Start the container with SSH
#   4. Run assertions
#   5. Tear down
#
# Each stage gets its own SSH port so all stages can run simultaneously.
# Output is buffered per stage and printed in order once all finish.
#
# Usage: scripts/test.sh [stage...]
# Env:   JAILBOX_TEST_AI_TOOLS  — AI tools to install (default: none)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

AI_TOOLS="${JAILBOX_TEST_AI_TOOLS:-}"
ALL_STAGES=(debian alpine fedora custom-user uid-mismatch)

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

Environment:
  JAILBOX_TEST_AI_TOOLS   AI tools to install inside the wrapper (default: none).
                          Example: JAILBOX_TEST_AI_TOOLS=claude $0 debian

Requires: podman, ssh, ssh-keygen
EOF
}

# Each stage gets a fixed dedicated port to allow parallel container runs.
stage_port() {
    case "$1" in
        debian)       echo 22229 ;;
        alpine)       echo 22230 ;;
        fedora)       echo 22231 ;;
        custom-user)  echo 22232 ;;
        uid-mismatch) echo 22233 ;;
        *) die "unknown stage: $1" ;;
    esac
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

setup_ssh_keys() {
    local ssh_dir="$1" dev_user="$2" port="$3"
    local key="$ssh_dir/key"
    rm -f "$key" "$key.pub"
    ssh-keygen -t ed25519 -f "$key" -N "" -q
    : > "$ssh_dir/known_hosts"
    chmod 600 "$ssh_dir/known_hosts"
    cat > "$ssh_dir/config" <<EOF
Host jailbox-test
    HostName localhost
    Port $port
    User $dev_user
    IdentityFile $key
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
    local i
    for i in $(seq 1 30); do
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

run_case() {
    local stage="$1"
    local log_dir="$2"
    local port dev_user test_build_args ctr
    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope. Initialize here so the trap can
    # always reference them safely under set -u.
    ssh_dir=""
    build_log=""

    port=$(stage_port "$stage")
    dev_user="devuser"
    test_build_args=()

    case "$stage" in
        custom-user)
            dev_user="appuser"
            test_build_args=(--build-arg "HOST_UID=$(id -u)")
            ;;
    esac

    local test_image="jailbox-test-${stage}"
    local wrapper_image="jailbox-wrapper-${stage}"
    ctr="jailbox-test-${stage}-ctr"
    ssh_dir=$(mktemp -d)
    build_log=$(mktemp)

    # Fires when the subshell exits — cleans up regardless of success/failure.
    trap 'echo "$PASSED $FAILED" > "'"$log_dir"'/'"$stage"'.counts"
          rm -rf "$ssh_dir" "$build_log"
          podman stop "'"$ctr"'" >/dev/null 2>&1 || true
          podman rm   "'"$ctr"'" >/dev/null 2>&1 || true' EXIT

    echo ""
    echo "── $stage (user: $dev_user, port: $port) ──────────────────────────────"

    podman stop "$ctr" 2>/dev/null || true
    podman rm   "$ctr" 2>/dev/null || true

    # Build test dev image
    if ! podman build \
            --target "$stage" \
            "${test_build_args[@]}" \
            -t "$test_image" \
            -f "$JAILBOX_DIR/Containerfile.test" \
            "$JAILBOX_DIR" > "$build_log" 2>&1; then
        fail "test image build"
        tail -20 "$build_log" >&2
        return 1
    fi

    # Build jailbox wrapper
    if ! podman build \
            -t "$wrapper_image" \
            -f "$JAILBOX_DIR/Containerfile.wrapper" \
            --build-arg "DEV_IMAGE=${test_image}" \
            --build-arg "USER_ID=$(id -u)" \
            --build-arg "DEV_USER=${dev_user}" \
            --build-arg "AI_TOOLS=${AI_TOOLS}" \
            "$JAILBOX_DIR" > "$build_log" 2>&1; then
        fail "wrapper image build"
        tail -20 "$build_log" >&2
        return 1
    fi

    pass "images build"

    setup_ssh_keys "$ssh_dir" "$dev_user" "$port"

    podman run -d \
        --name "$ctr" \
        --replace \
        --userns=keep-id \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --tmpfs /run:rw,size=64m \
        -p "127.0.0.1:${port}:2222" \
        -v "${ssh_dir}/key.pub:/home/${dev_user}/.ssh/authorized_keys:ro,Z" \
        --cap-drop=ALL \
        --cap-add=CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID,SYS_CHROOT \
        --security-opt=no-new-privileges \
        "$wrapper_image" >/dev/null

    if ! wait_for_ssh "$ssh_dir/config"; then
        fail "SSH ready"
        podman logs "$ctr" >&2 || true
        return 1
    fi

    pass "SSH ready"

    assert_eq "whoami is ${dev_user}"  "$dev_user" "$(ssh_run "$ssh_dir/config" whoami 2>/dev/null || true)"
    assert_eq "UID matches host"       "$(id -u)"  "$(ssh_run "$ssh_dir/config" id -u 2>/dev/null || true)"
    assert_ssh "$ssh_dir/config" "home dir exists"  "test -d /home/${dev_user}"
    assert_ssh "$ssh_dir/config" "no docker socket" "! test -S /var/run/docker.sock"
    assert_ssh "$ssh_dir/config" "no podman socket"  "! test -S /run/podman/podman.sock"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage; exit 0
    fi

    command -v podman     >/dev/null 2>&1 || die "podman is required"
    command -v ssh        >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"

    local stages=("$@")
    [ ${#stages[@]} -eq 0 ] && stages=("${ALL_STAGES[@]}")

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do [ "$s" = "$a" ] && valid=1 && break; done
        [ $valid -eq 1 ] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
    done

    local log_dir
    log_dir=$(mktemp -d)
    trap 'rm -rf "$log_dir"' EXIT

    echo "jailbox integration tests (parallel)"
    echo "Stages : ${stages[*]}"
    [ -n "$AI_TOOLS" ] && echo "AI_TOOLS: $AI_TOOLS"
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
                fi
                reported[$stage]=1
            elif ! kill -0 "${stage_pids[$stage]}" 2>/dev/null; then
                # Process exited without writing counts (early crash).
                printf "  ❌ %-16s (crashed)\n" "$stage"
                reported[$stage]=1
            fi
        done
        [[ ${#reported[@]} -lt ${#stages[@]} ]] && sleep 0.3
    done
    echo ""

    # Reap all background jobs.
    for pid in "${stage_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Print full per-stage output in defined order, then tally totals.
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
    [ $total_failed -eq 0 ] || exit 1
}

main "$@"
