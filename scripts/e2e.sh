#!/bin/bash
# E2E test for jailbox.
#
# For each stage: runs the full jailbox CLI, then while the container is still
# up runs headless SSH assertions covering security, tools, shell, and mounts.
# All stages run in parallel; output is buffered and printed in defined order.
#
# Prerequisites: run scripts/test.sh first to build the jailbox-test-* images.
#
# Usage: scripts/e2e.sh [stage...]
# Env:   JAILBOX_TEST_AI_TOOLS  — AI tools to install (default: none)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

AI_TOOLS="${JAILBOX_TEST_AI_TOOLS:-}"
ALL_STAGES=(debian alpine fedora custom-user uid-mismatch)

PASSED=0
FAILED=0
stub_dir=""

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

End-to-end jailbox tests. Runs the full CLI pipeline then verifies
security, tools, shell, and mounts via SSH.

Run scripts/test.sh first to build the jailbox-test-* images.

Stages: ${ALL_STAGES[*]}

Environment:
  JAILBOX_TEST_AI_TOOLS  AI tools to install (default: none).
EOF
}

# ── SSH assertion helpers ─────────────────────────────────────────────────────

e2e_ssh() {
    local config="$1" ctr="$2"; shift 2
    ssh -F "$config" -o ConnectTimeout=3 "$ctr" "$@" 2>/dev/null
}

assert_ssh() {
    local config="$1" ctr="$2" desc="$3"; shift 3
    if e2e_ssh "$config" "$ctr" "$@"; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

assert_ssh_fails() {
    local config="$1" ctr="$2" desc="$3"; shift 3
    if e2e_ssh "$config" "$ctr" "$@"; then
        fail "$desc (expected failure, got success)"
    else
        pass "$desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

# ── stub VS Code ──────────────────────────────────────────────────────────────
# Minimal stub: just verify jailbox called open_editor with the right argument.
# The real SSH assertions run after jailbox exits, while the container is up.

setup_stub_editor() {
    cat > "$stub_dir/code" << 'STUB'
#!/bin/bash
set -euo pipefail

container=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--remote" ]]; then
        container="${arg#ssh-remote+}"
    fi
    prev="$arg"
done

[[ -n "${JAILBOX_E2E_PROJECT:-}" ]] || { echo "stub: JAILBOX_E2E_PROJECT not set" >&2; exit 1; }
[[ -n "$container" ]] || { echo "stub: no ssh-remote+<container> argument received" >&2; exit 1; }

echo "stub: editor called for $container"
STUB
    chmod +x "$stub_dir/code"
    ln -sf "$stub_dir/code" "$stub_dir/codium"
}

# ── run_e2e_case ──────────────────────────────────────────────────────────────
# Designed to run inside a subshell. PASSED/FAILED are subshell-local.

run_e2e_case() {
    local stage="$1"
    local log_dir="$2"
    local dev_user="devuser"

    case "$stage" in
        custom-user) dev_user="appuser" ;;
    esac

    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope.
    project_dir=""

    trap 'echo "$PASSED $FAILED" > "'"$log_dir"'/'"$stage"'.counts"
          if [[ -n "$project_dir" ]]; then
              (cd "$project_dir" && "'"$JAILBOX_DIR"'/jailbox" --clean 2>/dev/null || true)
              rm -rf "$project_dir"
          fi' EXIT

    echo ""
    echo "── e2e: $stage (user: $dev_user) ─────────────────────────────────────"

    # Stable lowercase name — jailbox derives the image tag from basename(project_dir).
    project_dir="/tmp/jailbox-e2e-${stage}"
    rm -rf "$project_dir"
    mkdir -p "$project_dir"

    cat > "$project_dir/jailbox.conf" << EOF
DEV_IMAGE=jailbox-test-${stage}
DEV_USER=${dev_user}
AI_TOOLS=(${AI_TOOLS})
REMOTE_PATH=/home/${dev_user}/project
EOF

    export JAILBOX_E2E_PROJECT="$project_dir"

    # ── Phase 1: full jailbox pipeline ────────────────────────────────────────
    if (
        cd "$project_dir"
        PATH="$stub_dir:$PATH" "$JAILBOX_DIR/jailbox"
    ) 2>&1; then
        pass "pipeline (build → start → SSH wait → validation → editor stub)"
    else
        fail "pipeline failed"
        return 1
    fi

    # ── Phase 2: headless assertions (container still running) ────────────────
    local ssh_cfg="$project_dir/.ssh/config"
    local ctr="jailbox-e2e-${stage}-jailbox"

    # Host-side: ~/.ssh/config must include the project config for VS Code.
    if grep -qxF "Include $project_dir/.ssh/config" "$HOME/.ssh/config" 2>/dev/null; then
        pass "~/.ssh/config has Include (VS Code can resolve host)"
    else
        fail "~/.ssh/config missing Include — VS Code cannot resolve host"
    fi

    # Shell and tools
    assert_eq "login shell is bash" "/bin/bash" \
        "$(e2e_ssh "$ssh_cfg" "$ctr" "grep -m1 '^${dev_user}:' /etc/passwd | cut -d: -f7" || true)"
    assert_ssh "$ssh_cfg" "$ctr" ".bashrc sets PS1"     "grep -q PS1 ~/.bashrc"
    assert_ssh "$ssh_cfg" "$ctr" "bash available"       "command -v bash >/dev/null"
    assert_ssh "$ssh_cfg" "$ctr" "git available"        "git --version >/dev/null"

    # Mounts
    assert_ssh "$ssh_cfg" "$ctr" "home writable" "test -w \"\$HOME\""
    assert_ssh "$ssh_cfg" "$ctr" "project mount writable" \
        "touch /home/${dev_user}/project/.e2e-test && rm /home/${dev_user}/project/.e2e-test"

    # Security
    assert_ssh_fails "$ssh_cfg" "$ctr" "rootfs is read-only"  "touch /etc/.e2e-test"
    assert_ssh       "$ssh_cfg" "$ctr" "no docker socket"     "! test -S /var/run/docker.sock"
    assert_ssh       "$ssh_cfg" "$ctr" "no podman socket"     "! test -S /run/podman/podman.sock"
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

    for stage in "${stages[@]}"; do
        podman image exists "jailbox-test-${stage}" 2>/dev/null || \
            die "jailbox-test-${stage} not found — run scripts/test.sh first"
    done

    local log_dir
    log_dir=$(mktemp -d)
    stub_dir=$(mktemp -d)
    trap 'rm -rf "$log_dir" "$stub_dir"' EXIT

    setup_stub_editor

    echo "jailbox e2e tests (parallel)"
    echo "Stages : ${stages[*]}"
    [ -n "$AI_TOOLS" ] && echo "AI_TOOLS: $AI_TOOLS"
    echo ""

    local -A stage_pids=()
    for stage in "${stages[@]}"; do
        printf "  ⏳ %s\n" "$stage"
        ( run_e2e_case "$stage" "$log_dir" ) > "$log_dir/${stage}.log" 2>&1 &
        stage_pids[$stage]=$!
    done
    echo ""

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
                printf "  ❌ %-16s (crashed)\n" "$stage"
                reported[$stage]=1
            fi
        done
        [[ ${#reported[@]} -lt ${#stages[@]} ]] && sleep 0.3
    done
    echo ""

    for pid in "${stage_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

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
