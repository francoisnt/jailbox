#!/bin/bash
# A row is one job (three independent command fixtures). Each fault job keeps
# its healthy trace and every interruption in one worker's project identity.
lifecycle_jobs() {
    local row command policy
    while IFS= read -r row; do
        printf 'row.%s|row|%s\n' "${row%%|*}" "$row"
    done < <(lifecycle_matrix_rows)
    for command in up stop --clean; do
        for policy in false true; do
            if [[ "$command:$policy" = up:true ]]; then continue; fi
            printf 'fault.%s.%s|fault|%s|%s\n' "$command" "$policy" "$command" "$policy"
        done
    done
    printf '%s\n' 'fault.up.none|fault|up|none' 'fault.up.new-ephemeral|fault|up|new-ephemeral'
    printf '%s\n' 'resume|special|resume' 'removal|special|removal' \
        'dependency|special|dependency' 'inspection|special|inspection'
}

# Historical timings influence order only, never membership. Unknown sweeps
# start first; otherwise prefer measured long jobs and use stable name ties.
lifecycle_order_jobs() {
    local jobs="$1" timings="$2"
    awk -F '|' '
        FILENAME == ARGV[1] {
            if (NF != 2 || $1 !~ /^[a-z][a-z0-9.-]*$/ || $2 !~ /^[0-9]+$/ || length($2) > 9) {
                bad=1; exit 1
            }
            duration[$1]=$2; next
        }
        { priority=($1 in duration) ? duration[$1] : ($2 == "fault" ? 1000000000 : 0)
          print priority "|" $0 }
        END { if (bad) print "Invalid lifecycle timing record" > "/dev/stderr" }
    ' "$timings" "$jobs" | LC_ALL=C sort -t '|' -k1,1nr -k2,2 | cut -d '|' -f2-
}

lifecycle_fixed_cases() {
    local row command policy missing baseline
    while IFS='|' read -r row _; do
        for command in up stop --clean; do printf '%s.%s\n' "$row" "$command"; done
    done < <(lifecycle_matrix_rows)
    for command in up stop --clean; do
        for policy in false true; do
            [[ "$command:$policy" != up:true ]] || continue
            printf 'trace.%s.%s\n' "$command" "$policy"
        done
    done
    printf '%s\n' trace.up.none trace.up.new-ephemeral failed-new-container-cleanup
    for policy in false true; do
        for missing in false true; do printf 'failed-resume.%s.missing-proxy-%s\n' "$policy" "$missing"; done
        for command in up stop --clean; do printf 'home-inspection.%s.%s\n' "$policy" "$command"; done
    done
    for baseline in networks-only missing-dev; do printf 'failed-create.%s\n' "$baseline"; done
}

lifecycle_fault_cases() {
    local trace="$1" command="$2" policy="$3" event point=0 fault
    while IFS= read -r event; do
        point=$((point + 1))
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
