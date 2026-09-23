#!/bin/bash
# Shared Bash 4.4 process pool for repository tooling. Callers own traps,
# output, resource cleanup, and launch policy (including ledger registration).
PROCESS_POOL_LIMIT=1
PROCESS_POOL_RESULT=0
PROCESS_POOL_REPORT=:
PROCESS_POOL_PROGRESS=:
PROCESS_POOL_LAUNCHED_PID=""
declare -A PROCESS_POOL_LABELS=() PROCESS_POOL_STARTED=()

process_pool_init() {
    [[ "$1" =~ ^[1-9][0-9]{0,2}$ && -z ${!PROCESS_POOL_LABELS[*]} ]] || return 1
    PROCESS_POOL_LIMIT=$1
    PROCESS_POOL_REPORT=$2
    PROCESS_POOL_PROGRESS=${3:-:}
    PROCESS_POOL_RESULT=0
    PROCESS_POOL_LAUNCHED_PID=""
    PROCESS_POOL_LABELS=()
    PROCESS_POOL_STARTED=()
}

# Launch callbacks must return a direct, waitable child in
# PROCESS_POOL_LAUNCHED_PID, and explicitly handle their own failures.
process_pool_submit() {
    local label=$1 launcher=$2 pid
    shift 2
    while ((${#PROCESS_POOL_LABELS[@]} >= PROCESS_POOL_LIMIT)); do
        process_pool_poll
        ((${#PROCESS_POOL_LABELS[@]} < PROCESS_POOL_LIMIT)) || sleep 0.05
    done
    PROCESS_POOL_LAUNCHED_PID=""
    "$launcher" "$@" || { PROCESS_POOL_RESULT=1; return 1; }
    pid=$PROCESS_POOL_LAUNCHED_PID
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { PROCESS_POOL_RESULT=1; return 1; }
    PROCESS_POOL_LABELS[$pid]=$label
    PROCESS_POOL_STARTED[$pid]=$SECONDS
    PROCESS_POOL_LAUNCHED_PID=""
}

process_pool_poll() {
    local pid status elapsed
    for pid in "${!PROCESS_POOL_LABELS[@]}"; do
        kill -0 "$pid" 2>/dev/null && continue
        status=0
        wait "$pid" || status=$?
        elapsed=$((SECONDS - PROCESS_POOL_STARTED[$pid]))
        ((status == 0)) || PROCESS_POOL_RESULT=1
        "$PROCESS_POOL_REPORT" "${PROCESS_POOL_LABELS[$pid]}" "$status" "$elapsed" || PROCESS_POOL_RESULT=1
        unset 'PROCESS_POOL_LABELS[$pid]' 'PROCESS_POOL_STARTED[$pid]'
    done
    "$PROCESS_POOL_PROGRESS" || PROCESS_POOL_RESULT=1
}

process_pool_wait() {
    while [[ -n ${!PROCESS_POOL_LABELS[*]} ]]; do
        process_pool_poll
        [[ -z ${!PROCESS_POOL_LABELS[*]} ]] || sleep 0.05
    done
    return "$PROCESS_POOL_RESULT"
}

# By default allow workers to finish their own cleanup after TERM. A caller
# managing only disposable direct children may opt into bounded KILL escalation.
process_pool_cancel() {
    local timeout=${1:-} pid deadline
    [[ -z "$timeout" || "$timeout" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
    if [[ -n "$PROCESS_POOL_LAUNCHED_PID" ]]; then
        [[ "$PROCESS_POOL_LAUNCHED_PID" =~ ^[1-9][0-9]*$ ]] || return 1
        PROCESS_POOL_LABELS[$PROCESS_POOL_LAUNCHED_PID]='interrupted launch'
    fi
    for pid in "${!PROCESS_POOL_LABELS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    if [[ -n "$timeout" ]]; then
        deadline=$((SECONDS + timeout))
        for pid in "${!PROCESS_POOL_LABELS[@]}"; do
            while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do sleep 0.05; done
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
    for pid in "${!PROCESS_POOL_LABELS[@]}"; do wait "$pid" 2>/dev/null || true; done
    PROCESS_POOL_LABELS=()
    PROCESS_POOL_STARTED=()
    PROCESS_POOL_LAUNCHED_PID=""
}
