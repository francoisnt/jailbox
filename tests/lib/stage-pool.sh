#!/bin/bash
# Bounded integration stages. Each worker owns its resources until cleanup ends.
# Callers keep preparation and final ledger sweeps outside this scope.
# shellcheck source=scripts/lib/process-pool.sh
source "$JAILBOX_DIR/scripts/lib/process-pool.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$JAILBOX_DIR/scripts/lib/worker-resources.sh"

stage_pool_cleanup() {
    local status=$?
    trap - EXIT
    trap '' INT TERM HUP
    process_pool_cancel
    (eval "$stage_saved_traps"; exit "$status") || true
    exit "$status"
}

stage_pool_launch() {
    local stage=$1 index=$2
    local -a command=(bash "$JAILBOX_DIR/tests/lib/stage-worker.sh"
        "$stage_runner" "$stage_logs/worker-context" "$stage_callback"
        "$stage" "$stage_logs" "$index" "$stage_total")
    if declare -F ledger_start_worker >/dev/null; then
        ledger_start_worker exec "${command[@]}" > "$stage_logs/$stage.log" 2>&1 || return 1
        PROCESS_POOL_LAUNCHED_PID=$LEDGER_WORKER_PID
    else
        "${command[@]}" > "$stage_logs/$stage.log" 2>&1 &
        PROCESS_POOL_LAUNCHED_PID=$!
    fi
}

stage_pool_report() {
    local stage=$1 status=$2 elapsed=$3 passed failed
    if [[ -f "$stage_logs/$stage.counts" ]]; then
        read -r passed failed < "$stage_logs/$stage.counts" || status=1
        [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || status=1
        [[ "$failed" = 0 ]] || status=1
        if ((status != 0)); then
            [[ "$passed" =~ ^[0-9]+$ ]] || passed=0
            [[ "$failed" =~ ^[1-9][0-9]*$ ]] || failed=1
            printf '%s %s\n' "$passed" "$failed" > "$stage_logs/$stage.counts" || return 1
        fi
    else
        status=1
    fi
    printf '%s\n' "$status" > "$stage_logs/$stage.exit-status" || return 1
    printf '%s: status=%s, %ss\n' "$stage" "$status" "$elapsed" >> "$stage_logs/timings.log" || return 1
    stage_complete=$((stage_complete + 1))
    if ((status != 0)); then
        printf '\nStage failed: %s\n' "$stage"
        cat "$stage_logs/$stage.log"
    fi
    return "$status"
}

stage_pool_progress() {
    local interval=15
    [[ ${JAILBOX_TEST_PROGRESS_TERMINAL:-false} != true ]] || interval=1
    ((SECONDS - stage_last >= interval)) || return 0
    stage_last=$SECONDS
    printf 'Progress: Stages: %s/%s complete · %s running · %ss elapsed\n' \
        "$stage_complete" "$stage_total" "${#PROCESS_POOL_LABELS[@]}" "$((SECONDS - stage_started))"
}

run_stage_pool() {
    local workload=$1 stage_logs=$2 stage_callback=$3 stage_runner=$4
    shift 4
    local stage_total=$# stage_complete=0 stage_started=$SECONDS stage_last=$SECONDS
    local workers stage index=0 result=0 stage_saved_traps
    local name
    local -A seen=()
    # Reject duplicate fixed resource names before launching anything.
    for stage in "$@"; do
        [[ "$stage" =~ ^[a-z][a-z0-9-]*$ && -z ${seen[$stage]+x} ]] || return 1
        seen[$stage]=1
    done
    workers=$(worker_tool_budget "$workload") || return 1
    ((workers <= stage_total)) || workers=$stage_total
    ((workers > 0)) || return 1
    printf 'workers=%s\n' "$workers" > "$stage_logs/resources.log" || return 1
    # Only explicit runner-owned state crosses into the fresh Bash process.
    # NUL records preserve paths without evaluating shell text.
    (umask 077; : > "$stage_logs/worker-context") || return 1
    for name in $STAGE_WORKER_VARIABLES; do
        printf '%s\0%s\0' "$name" "${!name}" >> "$stage_logs/worker-context" || return 1
    done
    process_pool_init "$workers" stage_pool_report stage_pool_progress || return 1
    stage_saved_traps=$(trap -p EXIT INT TERM HUP)
    trap stage_pool_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    printf 'Stages: %s total · %s workers\n' "$stage_total" "$workers"
    for stage in "$@"; do
        index=$((index + 1))
        process_pool_submit "$stage" stage_pool_launch "$stage" "$index" || { result=1; break; }
    done
    process_pool_wait || result=1
    printf 'Stages finished: %s/%s · %ss elapsed · logs: %s\n' \
        "$stage_complete" "$stage_total" "$((SECONDS - stage_started))" "$stage_logs"
    trap - EXIT INT TERM HUP
    eval "$stage_saved_traps"
    return "$result"
}
