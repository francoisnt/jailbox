#!/bin/bash
# Bounded integration stages. Each worker owns its resources until cleanup ends.
# Callers own traps and must cancel/join workers before removing dependencies.
# shellcheck source=scripts/lib/process-pool.sh
source "$JAILBOX_DIR/scripts/lib/process-pool.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$JAILBOX_DIR/scripts/lib/worker-resources.sh"

# Published results belong to this adapter, not to the caller's assertion state.
STAGE_PASSED=0
STAGE_FAILED=0
STAGE_FAILED_STAGES=()

stage_pool_cancel() {
    # Registration publishes this PID before releasing the worker. Include it
    # if a signal arrived before launch transferred it into the process pool.
    if [[ -n ${LEDGER_WORKER_PID:-} ]]; then
        PROCESS_POOL_LAUNCHED_PID=$LEDGER_WORKER_PID
        LEDGER_WORKER_PID=""
    fi
    process_pool_cancel
}

stage_pool_launch() {
    local stage=$1 index=$2
    local -a command=(bash "$JAILBOX_DIR/tests/lib/stage-log.sh"
        "$stage_runner" "$stage_logs/worker-context" "$stage_callback"
        "$stage" "$stage_logs" "$index" "$stage_total")
    printf 'RUN   %s/%s\n' "$stage_group" "$stage"
    if declare -F ledger_start_worker >/dev/null; then
        ledger_start_worker exec "${command[@]}" > "$stage_logs/$stage.log" 2>&1 || { LEDGER_WORKER_PID=""; return 1; }
        PROCESS_POOL_LAUNCHED_PID=$LEDGER_WORKER_PID
        LEDGER_WORKER_PID=""
    else
        "${command[@]}" > "$stage_logs/$stage.log" 2>&1 &
        PROCESS_POOL_LAUNCHED_PID=$!
    fi
}

stage_pool_report() {
    local stage=$1 status=$2 elapsed=$3 passed=0 failed=1
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
    STAGE_PASSED=$((STAGE_PASSED + 10#$passed))
    # Every selected stage starts with one failure until a result replaces it;
    # a launch failure therefore cannot silently omit unscheduled stages.
    STAGE_FAILED=$((STAGE_FAILED + 10#$failed - 1))
    printf '%s\n' "$status" > "$stage_logs/$stage.exit-status" || return 1
    printf '%s: status=%s, %ss\n' "$stage" "$status" "$elapsed" >> "$stage_logs/timings.log" || return 1
    test_log_drain "$stage_logs/$stage.log" stage "$stage_group/$stage" || return 1
    test_log_close "$stage_logs/$stage.log"
    stage_complete=$((stage_complete + 1))
    if ((status != 0)); then
        stage_failed=$((stage_failed + 1))
        test_log_result FAIL "$stage_group/$stage" "$elapsed"
        test_log_group "$stage_group/$stage" "$stage_logs/$stage.log"
    else
        test_log_result PASS "$stage_group/$stage" "$elapsed"
        if [[ ${GITHUB_ACTIONS:-false} = true ]]; then
            test_log_group "$stage_group/$stage" "$stage_logs/$stage.log"
        fi
    fi
    if ((status == 0)); then unset 'stage_failures[$stage]'; fi
    return "$status"
}

stage_pool_progress() {
    local stage
    if ((SECONDS != stage_drain_last)); then
        stage_drain_last=$SECONDS
        for stage in "${PROCESS_POOL_LABELS[@]}"; do
            test_log_drain "$stage_logs/$stage.log" stage "$stage_group/$stage" || return 1
        done
    fi
    test_progress_due "$stage_last" "$SECONDS" || return 0
    stage_last=$SECONDS
    printf 'Progress: Stages: %s/%s done · %s running · %s failed · %ss\n' \
        "$stage_complete" "$stage_total" "${#PROCESS_POOL_LABELS[@]}" "$stage_failed" "$((SECONDS - stage_started))"
}

run_stage_pool() {
    local workload=$1 stage_group=$2 stage_logs=$3 stage_callback=$4 stage_runner=$5
    shift 5
    local stage_failed=0 stage_drain_last=-1
    local stage_total=$# stage_complete=0 stage_started=$SECONDS stage_last=-15
    local workers stage index=0 result=0
    local name
    local -A stage_failures=()
    STAGE_PASSED=0
    STAGE_FAILED=$stage_total
    STAGE_FAILED_STAGES=("$@")
    # Reject duplicate fixed resource names before launching anything.
    for stage in "$@"; do
        [[ "$stage" =~ ^[a-z][a-z0-9-]*$ && -z ${stage_failures[$stage]+x} ]] || return 1
        stage_failures[$stage]=1
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
    printf 'Stages: %s total · %s workers\n' "$stage_total" "$workers"
    for stage in "$@"; do
        index=$((index + 1))
        process_pool_submit "$stage" stage_pool_launch "$stage" "$index" || { result=1; break; }
    done
    process_pool_wait || result=1
    STAGE_FAILED_STAGES=()
    for stage in "$@"; do
        test_log_close "$stage_logs/$stage.log"
        [[ -z ${stage_failures[$stage]+x} ]] || STAGE_FAILED_STAGES+=("$stage")
    done
    test_progress_complete 'Stages finished: %s/%s · %ss elapsed · logs: %s\n' \
        "$stage_complete" "$stage_total" "$((SECONDS - stage_started))" "$stage_logs"
    return "$result"
}
