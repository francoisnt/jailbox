#!/bin/bash
# Manual test runner: cycles through jailbox test stages sequentially,
# opens VSCodium for each, prompts for a pass/fail result, and logs everything.
#
# Prerequisites: run tests/integration-images.sh first to build the jailbox-test-* images.
#
# Usage: tests/manual-vscodium.sh [stage...]
# With no arguments runs all stages in order.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

ALL_STAGES=(debian alpine fedora custom-user uid-mismatch)

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $(basename "$0") [stage...]

Cycle through jailbox stages, open VSCodium for each, and log results.

Stages: ${ALL_STAGES[*]}
Default: all stages in order.

Run tests/integration-images.sh first to build the jailbox-test-* images.
EOF
    exit 0
fi

# ── stage list ────────────────────────────────────────────────────────────────

stages=("$@")
if [[ ${#stages[@]} -eq 0 ]]; then
    stages=("${ALL_STAGES[@]}")
else
    for s in "${stages[@]}"; do
        valid=0
        for a in "${ALL_STAGES[@]}"; do [[ "$s" == "$a" ]] && valid=1 && break; done
        [[ $valid -eq 1 ]] || { echo "Error: unknown stage '$s'. Valid: ${ALL_STAGES[*]}" >&2; exit 1; }
    done
fi

# ── log file ──────────────────────────────────────────────────────────────────

LOG_DIR="$JAILBOX_DIR/testlog/manual-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/manual.log"
log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }

# ── result tracking ───────────────────────────────────────────────────────────

declare -A RESULTS=()   # stage → pass | fail | skip

# ── per-stage helpers ─────────────────────────────────────────────────────────

dev_user_for() {
    [[ "$1" == "custom-user" ]] && echo "appuser" || echo "devuser"
}

jailbox_container_name() {
    printf 'jailbox-%s\n' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

jailbox_ssh_config() {
    printf '%s/.jailbox/ssh_config\n' "$1"
}

write_jailbox_workspace_config() {
    local project_dir="$1"
    local ctr="$2"
    local remote_path="$3"

    mkdir -p "$project_dir/.jailbox"
    chmod 700 "$project_dir/.jailbox"
    printf '.jailbox/\n' > "$project_dir/.gitignore"
    cat > "$project_dir/.jailbox/jailbox.code-workspace" << EOF
{
  "folders": [
    {
      "uri": "vscode-remote://ssh-remote+${ctr}${remote_path}"
    }
  ],
  "settings": {
    "remote.SSH.configFile": "${project_dir}/.jailbox/ssh_config"
  }
}
EOF
    chmod 600 "$project_dir/.jailbox/jailbox.code-workspace"
}

collect_failure_diagnostics() {
    local stage="$1"
    local project_dir="$2"
    local dev_user="$3"
    local ctr="$4"
    local ssh_cfg
    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    local listening_on local_probe_port tunnel_pid

    log ""
    log "  Diagnostics for failed stage: $stage"
    log "  ──────────────────────────────────────────────────────────────────"

    if [[ ! -f "$ssh_cfg" ]]; then
        log "  SSH config missing: $ssh_cfg"
        return 0
    fi

    {
        echo ""
        echo "### remote processes"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "ps -o pid,ppid,args -A | grep -E 'codium|node|extension|server' | grep -v grep || true" 2>&1 || true

        echo ""
        echo "### vscodium server direct tunnel probe"
        listening_on=$(ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "grep -E 'Extension host agent listening on .+' /home/$dev_user/.vscodium-server/.*.log 2>/dev/null | tail -1 | sed 's/.*Extension host agent listening on //'" 2>/dev/null || true)
        if [[ -n "$listening_on" ]]; then
            local_probe_port=$(jailbox_pick_probe_port)
            ssh -F "$ssh_cfg" -N -L "127.0.0.1:${local_probe_port}:127.0.0.1:${listening_on}" "$ctr" >/dev/null 2>&1 &
            tunnel_pid=$!
            sleep 0.5
            if curl -sS --max-time 3 -D - -o /dev/null "http://127.0.0.1:${local_probe_port}/version" 2>&1; then
                echo "OpenSSH tunnel probe succeeded: local ${local_probe_port} -> remote ${listening_on}"
            else
                echo "OpenSSH tunnel probe failed: local ${local_probe_port} -> remote ${listening_on}"
            fi
            kill "$tunnel_pid" >/dev/null 2>&1 || true
            wait "$tunnel_pid" 2>/dev/null || true
        else
            echo "No listening port found in VSCodium server log"
        fi

        echo ""
        echo "### vscodium server logs"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "find /home/$dev_user/.vscodium-server -maxdepth 4 -type f -name '*.log' -print -exec sh -c 'echo --- \$1; tail -200 \"\$1\"' sh {} \\;" 2>&1 || true

        echo ""
        echo "### alpine package check"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "if command -v apk >/dev/null 2>&1; then apk info -e bash curl tar libgcc libstdc++ gcompat krb5-libs webkit2gtk-4.1; fi" 2>&1 || true
    } | while IFS= read -r line; do
        log "  $line"
    done
}

jailbox_pick_probe_port() {
    local port

    for port in $(seq 25000 25100); do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
            printf '%s\n' "$port"
            return 0
        fi
    done

    printf '%s\n' 25000
}

run_stage() {
    local stage="$1"
    local idx="$2"
    local total="$3"
    local dev_user project_dir ctr

    dev_user=$(dev_user_for "$stage")
    project_dir="/tmp/jailbox-manual-$stage"
    ctr=$(jailbox_container_name "$project_dir")

    # ── setup ────────────────────────────────────────────────────────────────

    rm -rf "$project_dir"
    mkdir -p "$project_dir"

    cat > "$project_dir/jailbox.conf" << EOF
DEV_IMAGE=jailbox-test-$stage
DEV_USER=$dev_user
REMOTE_PATH=/home/$dev_user/project
EOF
    echo "jailbox manual test — $stage" > "$project_dir/README.txt"
    write_jailbox_workspace_config "$project_dir" "$ctr" "/home/$dev_user/project"

    # Ensure cleanup on Ctrl-C or error during this stage.
    local cleaned=0
    stage_cleanup() {
        if [[ $cleaned -eq 0 ]]; then
            cleaned=1
            (
                cd "$project_dir"
                "$JAILBOX_DIR/jailbox" --clean 2>/dev/null || true
            )
            rm -rf "$project_dir"
        fi
    }
    trap 'stage_cleanup; exit 130' INT

    # ── header ───────────────────────────────────────────────────────────────

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf  "  Stage %d/%d  ·  %s  ·  user: %s  ·  UID: %s\n" \
        "$idx" "$total" "$stage" "$dev_user" "$(id -u)"
    printf  "  Host project dir  →  %s\n" "$project_dir"
    printf  "  Container mount   →  /home/%s/project\n" "$dev_user"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Headless checks (shell, tools, mounts, security) are covered by"
    echo "  tests/e2e-headless.sh. Verify only what requires a human + VS Code:"
    echo ""
    echo "    □ VSCodium opens and the bottom-left badge shows"
    echo "      SSH: <container-name>  (not 'local')"
    echo "    □ A terminal (Ctrl+\`) opens inside the container:"
    echo "      prompt shows  $dev_user@<container>:~/project\$"
    echo ""
    read -rp "  Press Enter to launch jailbox and open VSCodium..."
    echo ""

    # ── launch ────────────────────────────────────────────────────────────────

    ( cd "$project_dir" && "$JAILBOX_DIR/jailbox" )

    # codium --remote is non-blocking; container stays up until we clean up.
    echo ""
    echo "  VSCodium is open. Verify the two items above."
    echo ""

    # ── prompt ────────────────────────────────────────────────────────────────

    local result note
    while true; do
        read -rp "  Result for $stage — [p]ass / [f]ail / [s]kip: " result
        case "${result,,}" in
            p|pass)  result=pass;  break ;;
            f|fail)  result=fail;  break ;;
            s|skip)  result=skip;  break ;;
            *) echo "  Please enter p, f, or s." ;;
        esac
    done

    note=""
    if [[ "$result" != "skip" ]]; then
        read -rp "  Notes (optional, Enter to skip): " note || true
    fi

    RESULTS[$stage]="$result"

    if [[ "$result" == "fail" ]]; then
        collect_failure_diagnostics "$stage" "$project_dir" "$dev_user" "$ctr"
    fi

    # ── cleanup ───────────────────────────────────────────────────────────────

    stage_cleanup
    trap - INT   # restore default after stage

    # ── per-stage log entry ───────────────────────────────────────────────────

    local symbol
    case "$result" in
        pass) symbol="✅" ;;
        fail) symbol="❌" ;;
        skip) symbol="⏭ " ;;
    esac

    local entry="$symbol $stage"
    [[ -n "$note" ]] && entry="$entry — $note"
    log "  $entry"
}

# ── main ──────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  jailbox manual test run                                            ║"
printf "║  stages: %-60s ║\n" "${stages[*]}"
echo "╚══════════════════════════════════════════════════════════════════════╝"

{
    echo ""
    echo "jailbox manual test — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "stages: ${stages[*]}"
    echo ""
} >> "$LOG_FILE"

# Verify all images exist before starting.
for stage in "${stages[@]}"; do
    podman image exists "jailbox-test-$stage" 2>/dev/null || {
        echo "Error: jailbox-test-$stage not found — run tests/integration-images.sh first" >&2
        exit 1
    }
done

total=${#stages[@]}
idx=0
for stage in "${stages[@]}"; do
    idx=$((idx + 1))
    run_stage "$stage" "$idx" "$total"
    echo ""
done

# ── summary ───────────────────────────────────────────────────────────────────

passed=0 failed=0 skipped=0
for stage in "${stages[@]}"; do
    case "${RESULTS[$stage]:-skip}" in
        pass) passed=$((passed + 1)) ;;
        fail) failed=$((failed + 1)) ;;
        skip) skipped=$((skipped + 1)) ;;
    esac
done

{
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Results: $passed passed, $failed failed, $skipped skipped"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
} | tee -a "$LOG_FILE"

echo ""
echo "Full log: $LOG_FILE"

[[ $failed -eq 0 ]]
