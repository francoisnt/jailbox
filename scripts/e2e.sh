#!/bin/bash
# E2E test for jailbox.
#
# Runs the full jailbox CLI for each stage with a stub VS Code binary that
# verifies Remote SSH prerequisites (bash available, home writable).
# Each stage runs in parallel; output is buffered and printed in defined order.
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

End-to-end jailbox tests. Runs the full CLI pipeline — config load,
image build, container start, SSH wait, post-start validation — then
calls a stub VS Code that verifies Remote SSH prerequisites.

Run scripts/test.sh first to build the jailbox-test-* images.

Stages: ${ALL_STAGES[*]}

Environment:
  JAILBOX_TEST_AI_TOOLS  AI tools to install (default: none).
EOF
}

stage_port() { :; }  # jailbox derives its own port from the project name

# ── stub VS Code ──────────────────────────────────────────────────────────────
# Written to $stub_dir/{code,codium} and prepended to PATH before running jailbox.
# jailbox picks whichever of codium/code it finds first; the stub covers both.
# jailbox calls: <editor> --remote ssh-remote+<container> <remote-path>
# The stub uses the SSH config jailbox wrote to verify VS Code prerequisites.

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

project_dir="${JAILBOX_E2E_PROJECT:-}"
[[ -n "$project_dir" ]] || { echo "stub: JAILBOX_E2E_PROJECT not set" >&2; exit 1; }
[[ -n "$container"   ]] || { echo "stub: no ssh-remote+<container> arg" >&2; exit 1; }

ssh_config="$project_dir/.ssh/config"

# VS Code Remote SSH requires bash on the remote.
ssh -F "$ssh_config" "$container" "command -v bash >/dev/null" 2>/dev/null || \
    { echo "stub: bash not available in container" >&2; exit 1; }

# VS Code server installs to ~/.vscode-server — home must be writable.
ssh -F "$ssh_config" "$container" 'test -w "$HOME"' 2>/dev/null || \
    { echo "stub: home directory not writable" >&2; exit 1; }

echo "stub: prerequisites verified for $container"
STUB
    chmod +x "$stub_dir/code"
    # Cover codium too — jailbox prefers it over code when both are in PATH.
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

    # Not declared local: EXIT trap fires after function returns, at which
    # point local variables are out of scope.
    project_dir=""

    trap 'echo "$PASSED $FAILED" > "'"$log_dir"'/'"$stage"'.counts"
          if [[ -n "$project_dir" ]]; then
              (cd "$project_dir" && "'"$JAILBOX_DIR"'/jailbox" --clean 2>/dev/null || true)
              rm -rf "$project_dir"
          fi' EXIT

    echo ""
    echo "── e2e: $stage (user: $dev_user) ─────────────────────────────────────"

    # Use a stable lowercase name — jailbox derives the image tag from
    # basename(project_dir), and podman rejects uppercase or dots in tags.
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

    if (
        cd "$project_dir"
        PATH="$stub_dir:$PATH" "$JAILBOX_DIR/jailbox"
    ) 2>&1; then
        pass "pipeline + VS Code Remote SSH prerequisites"
    else
        fail "pipeline failed"
    fi
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
