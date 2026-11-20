#!/bin/bash
# shellcheck source=tests/lib/lifecycle-contracts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle-contracts.sh"
# shellcheck source=tests/lib/lifecycle-assertions.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle-assertions.sh"
# shellcheck source=tests/lib/fixture-ports.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixture-ports.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/worker-resources.sh"

# Fault jobs as key|command|policy[|piece|pieces]. A split scenario becomes one
# job per piece; unsplit scenarios keep their single job.
lifecycle_fault_jobs() {
    local command policy pieces piece
    local -a policies=()
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        read -r -a policies <<< "${LIFECYCLE_FAULT_SCENARIOS[$command]}"
        for policy in "${policies[@]}"; do
            pieces=$(lifecycle_fault_piece_count "$command" "$policy") || return 1
            if [[ "$pieces" = 1 ]]; then
                printf 'fault.%s.%s|%s|%s\n' "$command" "$policy" "$command" "$policy"
                continue
            fi
            for ((piece = 1; piece <= pieces; piece++)); do
                printf 'fault.%s.%s.p%s|%s|%s|%s|%s\n' "$command" "$policy" "$piece" \
                    "$command" "$policy" "$piece" "$pieces"
            done
        done
    done
}

# A row is one job (each command gets an independent fixture). Each fault job keeps
# its healthy trace and its interruptions in one worker's project identity.
lifecycle_jobs() {
    local row key rest faults
    validate_lifecycle_contracts
    validate_lifecycle_recovery_contracts || return 1
    faults=$(lifecycle_fault_jobs) || return 1
    while IFS= read -r row; do
        printf 'row.%s|row|%s\n' "${row%%|*}" "$row"
    done < <(lifecycle_matrix_rows)
    while IFS='|' read -r key rest; do
        printf '%s|fault|%s\n' "$key" "$rest"
    done <<< "$faults"
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
# and interruption sweeps belong only to the full matrix. The benchmark keeps
# its historical row/command combinations for repeatable measurements.
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

# Map each fixed case to the catalog job that runs it.
lifecycle_case_job() {
    case "$1" in
        trace.*) printf 'fault.%s\n' "${1#trace.}" ;;
        failed-resume.*) printf 'resume\n' ;;
        failed-new-container-cleanup) printf 'removal\n' ;;
        failed-create.*) printf 'dependency\n' ;;
        home-inspection.*) printf 'inspection\n' ;;
        ?*.?*) printf 'row.%s\n' "${1%.*}" ;;
        *) return 1 ;;
    esac
}

# Split the full catalog across CI machines. Timings only balance the shares:
# every job belongs to exactly one shard whatever the history contains.
lifecycle_select_shard() {
    local run="$1" shard="$2" count="$3" timings="$4" key job
    local -A catalog_jobs=() selected=()
    awk -F '|' -v default_weight=60 -f "${BASH_SOURCE[0]%/*}/lifecycle/order-jobs.awk" "$timings" "$run/catalog" \
        > "$run/shard-weights" || return 1
    LC_ALL=C sort -t '|' -k1,1nr -k2,2 "$run/shard-weights" |
        awk -F '|' -v shard="$shard" -v count="$count" -f "${BASH_SOURCE[0]%/*}/lifecycle/shard-jobs.awk" \
        > "$run/shard-catalog" || return 1
    rm -f -- "$run/shard-weights"
    while IFS='|' read -r key _; do
        [[ "$key" =~ ^[a-z][a-z0-9.-]*$ ]] || return 1
        catalog_jobs[$key]=1
    done < "$run/catalog"
    while IFS='|' read -r key _; do
        [[ "$key" =~ ^[a-z][a-z0-9.-]*$ ]] || return 1
        selected[$key]=1
    done < "$run/shard-catalog"
    : > "$run/shard-fixed" || return 1
    while IFS= read -r key; do
        job=$(lifecycle_case_job "$key") || { printf 'No lifecycle job owns case %s\n' "$key" >&2; return 1; }
        if [[ ! "$job" =~ ^[a-z][a-z0-9.-]*$ || ! -v catalog_jobs[$job] ]]; then
            printf 'Lifecycle case %s maps to unknown job %s\n' "$key" "$job" >&2
            return 1
        fi
        if [[ -v selected[$job] ]]; then printf '%s\n' "$key" >> "$run/shard-fixed" || return 1; fi
    done < "$run/expected-fixed"
    mv "$run/shard-catalog" "$run/catalog" || return 1
    mv "$run/shard-fixed" "$run/expected-fixed"
}

lifecycle_case_selected() {
    if [[ ${LIFECYCLE_SAMPLE_MODE:-false} != true ]]; then
        lifecycle_row_case_applies "$2"
        return $?
    fi
    local result=0
    grep -Fxq -- "$2" "$1/expected-fixed" || result=$?
    case "$result" in
        0|1) return "$result" ;;
        *) printf 'Could not read lifecycle sample selection\n' >&2; return 2 ;;
    esac
}

lifecycle_fixed_cases() {
    local row command policy missing baseline key faults
    validate_lifecycle_contracts
    validate_lifecycle_recovery_contracts || return 1
    faults=$(lifecycle_fault_jobs) || return 1
    while IFS='|' read -r row _; do
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
            lifecycle_row_case_applies "$row.$command" || continue
            printf '%s.%s\n' "$row" "$command"
        done
    done < <(lifecycle_matrix_rows)
    while IFS='|' read -r key _; do
        printf 'trace.%s\n' "${key#fault.}"
    done <<< "$faults"
    printf '%s\n' failed-new-container-cleanup
    for policy in false true; do
        for missing in false true; do printf 'failed-resume.%s.missing-proxy-%s\n' "$policy" "$missing"; done
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do printf 'home-inspection.%s.%s\n' "$policy" "$command"; done
    done
    for baseline in networks-only missing-dev; do printf 'failed-create.%s\n' "$baseline"; done
}

# A piece of a split sweep takes one contiguous share of the selected steps,
# keeping trace positions. Reordering inside a share cannot drop a step.
lifecycle_fault_cases() {
    local trace="$1" command="$2" policy="$3" piece="${4:-1}" pieces="${5:-1}"
    local event point=0 selected=0 total=0 first last fault
    [[ "$piece" =~ ^[1-9]$ && "$pieces" =~ ^[1-9]$ && "$piece" -le "$pieces" ]] || return 1
    while IFS= read -r event; do
        if lifecycle_fault_event_applies "$command" "$policy" "$event"; then total=$((total + 1)); fi
    done < "$trace"
    first=$(((piece - 1) * total / pieces + 1))
    last=$((piece * total / pieces))
    while IFS= read -r event; do
        point=$((point + 1))
        lifecycle_fault_event_applies "$command" "$policy" "$event" || continue
        selected=$((selected + 1))
        ((selected >= first && selected <= last)) || continue
        for fault in before after barrier; do
            # Allocation is covered before creation and by killing the
            # caller after allocation, before it receives the path. Do
            # not invent a failed mktemp that prints a success result.
            [[ "$event" != mktemp\ * || "$fault" != after ]] || continue
            printf 'interrupt.%s.%s.%s.%s\n' "$command" "$policy" "$point" "$fault"
        done
    done < "$trace"
}

# Check that each split sweep piece in the given runs' catalogs left exactly
# one recorded trace across those runs, and that a sweep's pieces performed the
# same operations in the same order, or their shares of the steps could
# misalign. One run checks its own pieces; CI passes every shard's run.
# Normalized traces are written to the first run.
lifecycle_check_piece_traces() {
    local run job kind pieces sweep normalized trace
    local -a split_jobs=() traces=()
    local -A references=()
    for run in "$@"; do
        while IFS='|' read -r job kind _ _ _ pieces; do
            [[ "$kind" = fault && -n "${pieces:-}" ]] || continue
            [[ "$job" =~ ^fault\.[a-z-]+\.[a-z][a-z-]*\.p[1-9]$ ]] || return 1
            split_jobs+=("$job")
        done < "$run/catalog" || return 1
    done
    for job in "${split_jobs[@]}"; do
        traces=()
        for run in "$@"; do
            for trace in "$run"/worker-*/"trace.${job#fault.}"/events; do
                if [[ -f "$trace" ]]; then traces+=("$trace"); fi
            done
        done
        if [[ ${#traces[@]} != 1 ]]; then
            printf 'Expected exactly one recorded trace for %s\n' "$job" >&2
            return 1
        fi
        sweep=${job#fault.}
        sweep=${sweep%.p[1-9]}
        normalized="$1/piece-trace.${job#fault.}"
        lifecycle_worker_neutral_event < "${traces[0]}" > "$normalized" || return 1
        if [[ ! -v references[$sweep] ]]; then
            references[$sweep]=$normalized
        elif ! cmp -s "${references[$sweep]}" "$normalized"; then
            printf 'Pieces of the %s sweep recorded different operations\n' "$sweep" >&2
            return 1
        fi
    done
}

# Atomic claims allow idle workers to take the next job without a central
# dispatcher or a shared stdin. A failed claimed job is never silently retried.
# After the coordinator records a failure, workers finish only their current job.
# Checking after the claim means a stop recorded before any claim is always seen;
# the abandoned claim leaves the job incomplete, so the run fails as expected.
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
        [[ ! -e "$run/stop" ]] || break
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


lifecycle_worker_budget() {
    worker_budget "$1" "$2" 2 2097152 1048576 16
}
