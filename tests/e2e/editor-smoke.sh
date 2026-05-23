#!/bin/bash
# Editor smoke test for jailbox.
#
# For each stage: creates a temporary VS Code/VSCodium workspace fixture with a
# .vscode/tasks.json validation task, launches the workspace through jailbox,
# opens the Remote SSH workspace with automatic tasks enabled, and verifies the
# proof file from the host.
#
# Prerequisites: run tests/integration/images.sh first to build the jailbox-test-* images.
#
# Usage: tests/e2e/editor-smoke.sh [stage...]
# Env:   JAILBOX_EDITOR_TIMEOUT seconds to wait for the proof file (default: 20)
#        JAILBOX_KEEP_FAILED=1 keeps failed temp projects/containers for diagnosis
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ALL_STAGES=(debian alpine fedora egress)
PROOF_FILE=".jailbox-editor-proof"
TASK_LABEL="jailbox: validate remote session"
EDITOR_TIMEOUT="${JAILBOX_EDITOR_TIMEOUT:-20}"

PASSED=0
FAILED=0
LOG_DIR=""
RUN_LOG=""

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

jailbox_container_name() {
    printf 'jailbox-%s\n' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

jailbox_ssh_config() {
    printf '%s/.jailbox/ssh_config\n' "$1"
}

jailbox_editor_user_data() {
    local project_dir="$1"
    local hash

    hash=$(printf '%s' "$project_dir" | cksum | cut -d' ' -f1)
    printf '%s/jailbox/editor-profiles/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$hash"
}

stage_test_image() {
    case "$1" in
        egress) echo "jailbox-test-debian" ;;
        *)      echo "jailbox-test-$1" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

Launch VSCodium/VS Code through jailbox and verify a Remote SSH task creates
$PROOF_FILE in a temporary workspace.

Stages: ${ALL_STAGES[*]}
Default: all stages in order.

Requires: podman, ssh, ssh-keygen, VSCodium or VS Code CLI.
Run tests/integration/images.sh first to build the jailbox-test-* images.

Environment:
  JAILBOX_EDITOR_TIMEOUT  Seconds to wait for $PROOF_FILE (default: 20)
  JAILBOX_KEEP_FAILED=1   Keep failed temp workspaces/containers for diagnosis
EOF
}

setup_logging() {
    LOG_DIR="$JAILBOX_DIR/testlog/editor-$(date +%Y%m%d-%H%M%S)-$$"
    RUN_LOG="$LOG_DIR/editor-smoke.log"
    mkdir -p "$LOG_DIR"
}

log_run() {
    printf '%s\n' "$*" | tee -a "$RUN_LOG"
}

run_stage_logged() {
    local stage="$1"
    local idx="$2"
    local total="$3"
    local stage_log="$LOG_DIR/${stage}.log"

    printf 'LOG %s %s\n' "$stage" "$stage_log" >> "$RUN_LOG"
    if run_stage "$stage" "$idx" "$total" > >(tee "$stage_log") 2>&1; then
        return 0
    fi

    return 1
}

editor_bin() {
    if command -v codium >/dev/null 2>&1; then
        command -v codium
    elif command -v code >/dev/null 2>&1; then
        command -v code
    else
        return 1
    fi
}

have_display() {
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

write_fixture() {
    local project_dir="$1"
    local stage="$2"
    local run_id="$3"
    local dev_image

    dev_image=$(stage_test_image "$stage")

    mkdir -p "$project_dir/.vscode"
    cat > "$project_dir/jailbox.conf" <<EOF
DEV_IMAGE=${dev_image}
REMOTE_PATH=/home/jailbox/project
EOF
    if [[ "$stage" == "egress" ]]; then
        printf 'EGRESS_ALLOW=api.ipify.org,github.com,githubusercontent.com\n' >> "$project_dir/jailbox.conf"
    fi

    cat > "$project_dir/README.txt" <<EOF
jailbox editor smoke fixture for $stage
EOF
    printf '%s\n' "$run_id" > "$project_dir/.jailbox-editor-run-id"

    cat > "$project_dir/.vscode/tasks.json" <<'EOF'
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "jailbox: validate remote session",
      "type": "shell",
      "command": "set -eu; proof=.jailbox-editor-proof; run_id=$(cat .jailbox-editor-run-id); test -n \"$run_id\"; write_probe=.jailbox-editor-write-check; : > \"$write_probe\"; { echo \"run_id=$run_id\"; echo \"whoami=$(whoami)\"; echo \"uid=$(id -u)\"; echo \"hostname=$(hostname)\"; echo \"pwd=$(pwd)\"; echo \"date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)\"; echo \"REMOTE_CONTAINERS=${REMOTE_CONTAINERS:-}\"; echo \"VSCODE_IPC_HOOK_CLI=${VSCODE_IPC_HOOK_CLI:-}\"; test -f /run/jailbox-sshd/authorized_keys && echo \"authorized_keys=present\"; test -w . && echo \"workspace_writable=yes\"; echo \"HTTP_PROXY=${HTTP_PROXY:-}\"; echo \"HTTPS_PROXY=${HTTPS_PROXY:-}\"; echo \"NO_PROXY=${NO_PROXY:-}\"; if [ -n \"${HTTPS_PROXY:-}\" ]; then echo \"proxy_configured=yes\"; else echo \"proxy_configured=no\"; fi; } > \"$proof\"; rm -f \"$write_probe\"; test \"$(whoami)\" = jailbox; test -f /run/jailbox-sshd/authorized_keys; test -w .; echo \"jailbox editor task validation passed\"",
      "options": {
        "cwd": "${workspaceFolder}"
      },
      "group": {
        "kind": "build",
        "isDefault": true
      },
      "runOptions": {
        "runOn": "folderOpen"
      },
      "problemMatcher": []
    }
  ]
}
EOF
}

write_editor_test_settings() {
    local project_dir="$1"
    local user_data settings base

    user_data=$(jailbox_editor_user_data "$project_dir")
    settings="$user_data/User/settings.json"

    # Extend jailbox's generated settings rather than replace them. Jailbox
    # already wrote the SSH config path, proxy settings, etc. The smoke test
    # only adds what the product deliberately omits: test-harness-specific keys
    # that enable automatic task execution and disable the trust prompt.
    base=$(head -n -1 "$settings")
    {
        printf '%s,\n' "$base"
        printf '  "security.workspace.trust.enabled": false,\n'
        printf '  "task.allowAutomaticTasks": "on"\n'
        printf '}\n'
    } > "${settings}.tmp" && mv "${settings}.tmp" "$settings"
    chmod 600 "$settings"
}

launch_editor_workspace() {
    local project_dir="$1"
    local ctr="$2"
    local bin user_data

    bin=$(editor_bin) || return 1
    user_data=$(jailbox_editor_user_data "$project_dir")

    "$bin" --user-data-dir "$user_data" \
        --new-window \
        --remote "ssh-remote+$ctr" \
        /home/jailbox/project
}

close_editor_workspace() {
    local project_dir="$1"
    local ctr="$2"
    local bin user_data

    bin=$(editor_bin) || return 0
    user_data=$(jailbox_editor_user_data "$project_dir")

    "$bin" --user-data-dir "$user_data" \
        --reuse-window \
        --remote "ssh-remote+$ctr" \
        /home/jailbox/project \
        --command workbench.action.closeWindow >/dev/null 2>&1 || true
}

terminate_editor_profile() {
    local project_dir="$1"
    local user_data pid

    user_data=$(jailbox_editor_user_data "$project_dir")

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$$" ]] && continue
        kill "$pid" >/dev/null 2>&1 || true
    done < <(
        ps -eo pid=,args= |
            awk -v user_data="$user_data" '
                index($0, "--user-data-dir " user_data) ||
                index($0, "--user-data-dir=" user_data) {
                    print $1
                }
            '
    )
}

cleanup_editor_workspace() {
    local project_dir="$1"
    local ctr="$2"

    close_editor_workspace "$project_dir" "$ctr"
    sleep 0.5
    terminate_editor_profile "$project_dir"
}

wait_for_proof() {
    local proof_path="$1"
    local deadline

    deadline=$((SECONDS + EDITOR_TIMEOUT))
    while (( SECONDS < deadline )); do
        if [[ -f "$proof_path" ]]; then
            return 0
        fi
        sleep 1
    done

    return 1
}

assert_proof_contains() {
    local proof_path="$1"
    local needle="$2"
    local desc="$3"

    if grep -Fqx "$needle" "$proof_path"; then
        pass "$desc"
        return 0
    else
        fail "$desc"
        return 1
    fi
}

validate_proof() {
    local project_dir="$1"
    local stage="$2"
    local run_id="$3"
    local proof_path
    local rc=0

    proof_path="$project_dir/$PROOF_FILE"

    if [[ -f "$proof_path" && ! -L "$proof_path" ]]; then
        pass "proof file exists in temp workspace"
    else
        fail "proof file exists in temp workspace"
        return 1
    fi

    assert_proof_contains "$proof_path" "run_id=$run_id" "proof file belongs to this test run" || rc=1
    assert_proof_contains "$proof_path" "whoami=jailbox" "task ran as jailbox user" || rc=1
    assert_proof_contains "$proof_path" "authorized_keys=present" "sshd authorized_keys visible in container" || rc=1
    assert_proof_contains "$proof_path" "workspace_writable=yes" "remote workspace is writable" || rc=1
    assert_proof_contains "$proof_path" "pwd=/home/jailbox/project" "task cwd is the mounted remote workspace" || rc=1

    if [[ "$stage" == "egress" ]]; then
        assert_proof_contains "$proof_path" "proxy_configured=yes" "proxy env visible when EGRESS_ALLOW is configured" || rc=1
    fi

    return "$rc"
}

collect_failure_diagnostics() {
    local stage="$1"
    local project_dir="$2"
    local ctr="$3"
    local proof_path ssh_cfg

    proof_path="$project_dir/$PROOF_FILE"
    ssh_cfg=$(jailbox_ssh_config "$project_dir")

    echo ""
    echo "  Diagnostics for failed stage: $stage"
    echo "  Project dir: $project_dir"
    echo "  Container:   $ctr"
    echo "  SSH config:  $ssh_cfg"
    if [[ -f "$project_dir/.jailbox-editor-run-id" ]]; then
        echo "  Run id:      $(cat "$project_dir/.jailbox-editor-run-id")"
    fi
    echo ""

    if [[ -f "$proof_path" ]]; then
        echo "  Proof file:"
        sed 's/^/    /' "$proof_path"
    else
        echo "  Proof file was not created: $proof_path"
    fi

    echo ""
    echo "  Task fixture:"
    sed 's/^/    /' "$project_dir/.vscode/tasks.json" || true

    if [[ -f "$ssh_cfg" ]]; then
        echo ""
        echo "  Remote workspace listing:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "pwd; ls -la /home/jailbox/project; printf 'run_id_file='; cat /home/jailbox/project/.jailbox-editor-run-id 2>/dev/null || true; env | grep -E '^(HTTP|HTTPS|NO)_PROXY=' || true" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Managed downloader proxy blocks:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "for f in \"\$HOME/.curlrc\" \"\$HOME/.wgetrc\"; do echo --- \$f; if [ -f \"\$f\" ]; then sed -n '/# >>> jailbox managed proxy >>>/,/# <<< jailbox managed proxy <<</p' \"\$f\"; else echo '(missing)'; fi; done" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Remote editor/server processes:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "ps -o pid,ppid,args -A | grep -E 'codium|code|node|extension|server|task' | grep -v grep || true" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  VSCodium/VS Code server logs:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "find /home/jailbox -maxdepth 5 \\( -path '/home/jailbox/.vscodium-server/*' -o -path '/home/jailbox/.vscode-server/*' \\) -type f -name '*.log' -print -exec sh -c 'echo --- \$1; tail -120 \"\$1\"' sh {} \\;" \
            2>&1 | sed 's/^/    /' || true
    fi
}

cleanup_stage() {
    local project_dir="$1"

    if [[ -n "$project_dir" ]]; then
        if (
            cd "$project_dir"
            "$JAILBOX_DIR/jailbox" --clean 2>/dev/null
        ); then
            :
        fi
        rm -rf "$project_dir"
    fi
}

run_stage() {
    local stage="$1"
    local idx="$2"
    local total="$3"
    local project_dir ctr proof_path run_id rc editor_opened

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  Stage %d/%d  ·  %s\n" "$idx" "$total" "$stage"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    project_dir=$(mktemp -d "/tmp/jailbox-editor-${stage}.XXXXXX")
    ctr=$(jailbox_container_name "$project_dir")
    proof_path="$project_dir/$PROOF_FILE"
    run_id="$(date +%s)-$$-$stage"
    rc=0
    editor_opened=0

    write_fixture "$project_dir" "$stage" "$run_id"

    if (
        cd "$project_dir"
        "$JAILBOX_DIR/jailbox"
    ) 2>&1; then
        pass "jailbox launched editor workspace"
        editor_opened=1
    else
        fail "jailbox launched editor workspace"
        rc=1
    fi

    if [[ "$rc" -eq 0 ]]; then
        write_editor_test_settings "$project_dir"
        # jailbox opens the workspace once before test-only settings are added.
        # Close that bootstrap window, then reopen in a fresh window so the
        # folder-open task runs with the smoke test profile settings.
        cleanup_editor_workspace "$project_dir" "$ctr"
        if launch_editor_workspace "$project_dir" "$ctr" 2>&1; then
            pass "opened editor workspace for automatic task: $TASK_LABEL"
        else
            fail "opened editor workspace for automatic task: $TASK_LABEL"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Waiting up to ${EDITOR_TIMEOUT}s for automatic task proof: $PROOF_FILE..."
        if wait_for_proof "$proof_path"; then
            pass "proof file was created by automatic editor task"
        else
            fail "proof file was created by automatic editor task"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        validate_proof "$project_dir" "$stage" "$run_id" || rc=1
    fi

    if [[ "$rc" -ne 0 ]]; then
        collect_failure_diagnostics "$stage" "$project_dir" "$ctr"
        if [[ "$editor_opened" -eq 1 ]]; then
            cleanup_editor_workspace "$project_dir" "$ctr"
        fi
        if [[ "${JAILBOX_KEEP_FAILED:-}" == "1" ]]; then
            echo ""
            echo "  Keeping failed workspace and container because JAILBOX_KEEP_FAILED=1"
            echo "  Workspace: $project_dir"
            return 1
        fi
    fi

    if [[ "$editor_opened" -eq 1 ]]; then
        cleanup_editor_workspace "$project_dir" "$ctr"
    fi
    cleanup_stage "$project_dir"
    return "$rc"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    command -v podman     >/dev/null 2>&1 || die "podman is required"
    command -v ssh        >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
    command -v cksum      >/dev/null 2>&1 || die "cksum is required"
    editor_bin >/dev/null || die "neither 'codium' nor 'code' was found in PATH"
    have_display || die "no graphical display session found; run with tests/run-all.sh --skip-editor on headless hosts"
    [[ "$EDITOR_TIMEOUT" =~ ^[0-9]+$ ]] || die "JAILBOX_EDITOR_TIMEOUT must be a positive integer"
    [[ "$EDITOR_TIMEOUT" -gt 0 ]] || die "JAILBOX_EDITOR_TIMEOUT must be greater than zero"

    local stages=("$@")
    [[ ${#stages[@]} -eq 0 ]] && stages=("${ALL_STAGES[@]}")

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do
            [[ "$s" == "$a" ]] && valid=1 && break
        done
        [[ "$valid" -eq 1 ]] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
    done

    local required_image
    for stage in "${stages[@]}"; do
        required_image=$(stage_test_image "$stage")
        podman image exists "$required_image" 2>/dev/null || \
            die "$required_image not found - run tests/integration/images.sh first"
    done

    setup_logging

    log_run "jailbox editor smoke test"
    log_run "Stages : ${stages[*]}"
    log_run "Task   : $TASK_LABEL"
    log_run "Timeout: ${EDITOR_TIMEOUT}s"
    log_run "Logs   : $LOG_DIR"
    log_run ""
    log_run "This test opens a graphical editor window and automates validation after launch."
    log_run ""

    local total=${#stages[@]}
    local idx=0
    local failed_stages=()

    for stage in "${stages[@]}"; do
        idx=$((idx + 1))
        if run_stage_logged "$stage" "$idx" "$total"; then
            printf 'PASS %s\n' "$stage" >> "$RUN_LOG"
        else
            printf 'FAIL %s\n' "$stage" >> "$RUN_LOG"
            failed_stages+=("$stage")
        fi
    done

    log_run ""
    log_run "──────────────────────────────────────────────────────────────────────"
    log_run "Results: $PASSED passed, $FAILED failed"
    if [[ ${#failed_stages[@]} -gt 0 ]]; then
        log_run "Failed stages: ${failed_stages[*]}"
    fi
    log_run "Full logs: $LOG_DIR"

    [[ "$FAILED" -eq 0 ]]
}

main "$@"
