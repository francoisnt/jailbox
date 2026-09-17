#!/bin/bash
# shellcheck source=tests/lib/lifecycle-contracts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle-contracts.sh"
# shellcheck source=tests/lib/fixture-ports.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixture-ports.sh"

# A row is one job (three independent command fixtures). Each fault job keeps
# its healthy trace and every interruption in one worker's project identity.
lifecycle_jobs() {
    local row command policy
    local -a policies=()
    validate_lifecycle_contracts
    while IFS= read -r row; do
        printf 'row.%s|row|%s\n' "${row%%|*}" "$row"
    done < <(lifecycle_matrix_rows)
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        read -r -a policies <<< "${LIFECYCLE_FAULT_SCENARIOS[$command]}"
        for policy in "${policies[@]}"; do
            printf 'fault.%s.%s|fault|%s|%s\n' "$command" "$policy" "$command" "$policy"
        done
    done
    printf '%s\n' 'resume|special|resume' 'removal|special|removal' \
        'dependency|special|dependency' 'inspection|special|inspection'
}

# Historical timings influence order only, never membership. Unknown sweeps
# start first; otherwise prefer measured long jobs and use stable name ties.
lifecycle_order_jobs() {
    local jobs="$1" timings="$2"
    awk -F '|' -f "${BASH_SOURCE[0]%/*}/lifecycle/order-jobs.awk" "$timings" "$jobs" | LC_ALL=C sort -t '|' -k1,1nr -k2,2 | cut -d '|' -f2-
}

# A deterministic benchmark prefix of constructed state/command cases. Keep
# row jobs intact except for the last row's unselected commands. Fault discovery
# and interruption sweeps belong only to the full matrix.
lifecycle_select_sample() {
    local run="$1" limit="${2:-50}" job kind key rest command record count=0
    case "$limit" in 50|150) ;; *) return 1 ;; esac
    : > "$run/sample-catalog" || return 1
    : > "$run/expected-fixed" || return 1
    while IFS='|' read -r job kind key rest; do
        [[ "$kind" = row ]] || continue
        ((count < limit)) || break
        printf '%s|%s|%s|%s\n' "$job" "$kind" "$key" "$rest" >> "$run/sample-catalog" || return 1
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
            ((count < limit)) || break
            printf '%s.%s\n' "$key" "$command" >> "$run/expected-fixed" || return 1
            count=$((count + 1))
        done
    done < "$run/catalog"
    if [[ "$limit" = 150 ]]; then
        # The larger sample covers every row plus the complete six-case
        # inspection job. Fail explicitly if catalog growth changes that fit.
        [[ "$count" = 144 ]] || { printf '150-case sample requires 144 row cases\n' >&2; return 1; }
        local inspection_jobs=0
        while IFS= read -r record; do
            IFS='|' read -r job kind key rest <<< "$record"
            if [[ "$kind:$key" = special:inspection ]]; then
                printf '%s\n' "$record" >> "$run/sample-catalog" || return 1
                inspection_jobs=$((inspection_jobs + 1))
            fi
        done < "$run/catalog"
        [[ "$inspection_jobs" = 1 ]] || return 1
        lifecycle_fixed_cases > "$run/sample-fixed" || return 1
        while IFS= read -r key; do
            [[ "$key" = home-inspection.* ]] || continue
            printf '%s\n' "$key" >> "$run/expected-fixed" || return 1
            count=$((count + 1))
        done < "$run/sample-fixed"
        rm "$run/sample-fixed" || return 1
    fi
    [[ "$count" = "$limit" ]] || { printf 'Not enough declared cases for a %s-case sample\n' "$limit" >&2; return 1; }
    mv "$run/sample-catalog" "$run/catalog"
}

lifecycle_case_selected() {
    [[ ${LIFECYCLE_SAMPLE_MODE:-false} = true ]] || return 0
    local result=0
    grep -Fxq -- "$2" "$1/expected-fixed" || result=$?
    case "$result" in
        0|1) return "$result" ;;
        *) printf 'Could not read lifecycle sample selection\n' >&2; return 2 ;;
    esac
}

lifecycle_fixed_cases() {
    local row command policy missing baseline
    local -a policies=()
    validate_lifecycle_contracts
    while IFS='|' read -r row _; do
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do printf '%s.%s\n' "$row" "$command"; done
    done < <(lifecycle_matrix_rows)
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        read -r -a policies <<< "${LIFECYCLE_FAULT_SCENARIOS[$command]}"
        for policy in "${policies[@]}"; do
            printf 'trace.%s.%s\n' "$command" "$policy"
        done
    done
    printf '%s\n' failed-new-container-cleanup
    for policy in false true; do
        for missing in false true; do printf 'failed-resume.%s.missing-proxy-%s\n' "$policy" "$missing"; done
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do printf 'home-inspection.%s.%s\n' "$policy" "$command"; done
    done
    for baseline in networks-only missing-dev; do printf 'failed-create.%s\n' "$baseline"; done
}

lifecycle_fault_cases() {
    local trace="$1" command="$2" policy="$3" event point=0 fault
    while IFS= read -r event; do
        point=$((point + 1))
        lifecycle_fault_event_applies "$policy" "$event" || continue
        for fault in before after barrier; do
            [[ "$event" != mktemp\ * || "$fault" != after ]] || continue
            printf 'interrupt.%s.%s.%s.%s\n' "$command" "$policy" "$point" "$fault"
        done
    done < "$trace"
}

# Atomic claims allow idle workers to take the next job without a central
# dispatcher or a shared stdin. A failed claimed job is never silently retried.
lifecycle_run_queue() {
    local run="$1" callback="$2" queue_fd key started
    local -a fields=()
    exec {queue_fd}< "$run/jobs"
    while IFS='|' read -r -u "$queue_fd" -a fields; do
        key=${fields[0]}
        [[ "$key" =~ ^[a-z][a-z0-9.-]*$ ]] || return 1
        if ! mkdir "$run/claims/$key" 2>/dev/null; then
            [[ -d "$run/claims/$key" ]] || return 1
            continue
        fi
        started=$SECONDS
        "$callback" "${fields[@]:1}"
        printf '%s|%s\n' "$key" "$((SECONDS - started))" > "$run/done/$key"
    done
    exec {queue_fd}<&-
}

lifecycle_dispatch_job() {
    local kind="$1"
    shift
    case "$kind" in
        row) run_row "$@" ;;
        fault) run_mutation_faults "$@" ;;
        special)
            case "$1" in
                resume) run_failed_resume ;;
                removal) run_removal_failure ;;
                dependency) run_existing_dependency_failure ;;
                inspection) run_home_inspection_failure ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# Stable case numbers within each type (or interruption trace). Workers may
# execute these out of order; completion counts below describe actual progress.
lifecycle_case_label() {
    local run="$1" key="$2"
    local -a manifests=("$run/expected-fixed")
    local file
    for file in "$run"/worker-*/expected-faults; do
        [[ ! -f "$file" ]] || manifests+=("$file")
    done
    awk -v key="$key" -f "${BASH_SOURCE[0]%/*}/lifecycle/case-label.awk" "${manifests[@]}"
}

# Read independently owned manifests: no shared lock can strand workers on
# cancellation. Totals remain explicitly provisional until discovery finishes.
lifecycle_progress() {
    local run="$1" file
    local -a manifests=("$run/expected-fixed") completed=()
    for file in "$run"/worker-*/expected-faults; do
        [[ ! -f "$file" ]] || manifests+=("$file")
    done
    for file in "$run"/worker-*/cases; do
        [[ ! -f "$file" ]] || completed+=("$file")
    done
    awk -F '|' -f "${BASH_SOURCE[0]%/*}/lifecycle/progress.awk" "${completed[@]}" "${manifests[@]}"
}

# Startup sizing is a scheduling estimate, not a memory reservation. Use the
# process CPU affinity and visible cgroup-v2 ancestors, including containers
# whose cgroup namespace exposes their own limits at the mount root.
lifecycle_worker_resources() {
    local proc=$1 cgroup=$2 cpus=${3:-}
    local memory relative directory quota period limit used available
    if [[ -z "$cpus" ]]; then cpus=$(nproc 2>/dev/null) || cpus=1; fi
    [[ "$cpus" =~ ^[1-9][0-9]{0,5}$ ]] || cpus=1
    memory=$(awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$proc/meminfo" 2>/dev/null) || memory=0
    [[ "$memory" =~ ^[0-9]{1,12}$ ]] || memory=0
    memory=$((10#$memory))
    relative=$(awk -F: '$1 == "0" && $2 == "" {print $3; exit}' "$proc/self/cgroup" 2>/dev/null) || relative=""
    # Unknown or legacy cgroup layouts cannot establish usable headroom.
    if [[ "$relative" != /* || "$relative" = *'/../'* || "$relative" = */.. || ! -d "$cgroup$relative" ]]; then
        printf '1|0\n'; return
    fi
    directory="$cgroup${relative%/}"
    while :; do
        if [[ -f "$directory/cpu.max" ]]; then
            quota=""; period=""
            read -r quota period < "$directory/cpu.max" || true
            if [[ "$quota" != max ]]; then
                if [[ "$quota" =~ ^[0-9]{1,12}$ && "$period" =~ ^[1-9][0-9]{0,11}$ ]]; then
                    available=$((10#$quota / 10#$period))
                    ((available >= 1)) || available=1
                    if ((available < cpus)); then cpus=$available; fi
                else
                    cpus=1
                fi
            fi
        fi
        if [[ -f "$directory/memory.max" ]]; then
            limit=""; used=""
            read -r limit < "$directory/memory.max" || true
            if [[ "$limit" != max ]]; then
                if [[ -r "$directory/memory.current" ]]; then read -r used < "$directory/memory.current" || true; fi
                if [[ "$limit" =~ ^[0-9]{1,15}$ && "$used" =~ ^[0-9]{1,15}$ ]]; then
                    available=$(((10#$limit - 10#$used) / 1024))
                    ((available >= 0)) || available=0
                    if ((available < memory)); then memory=$available; fi
                else
                    memory=0
                fi
            fi
        fi
        [[ "$directory" != "$cgroup" ]] || break
        directory=${directory%/*}
    done
    printf '%s|%s\n' "$cpus" "$memory"
}

lifecycle_worker_budget() {
    local cpus="$1" memory="$2" workers memory_workers
    workers=$((cpus / 2))
    memory_workers=$(((memory - 1048576) / 2097152))
    if ((memory_workers < workers)); then workers=$memory_workers; fi
    ((workers >= 1)) || workers=1
    ((workers <= 16)) || workers=16
    printf '%s\n' "$workers"
}
