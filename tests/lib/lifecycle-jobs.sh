#!/bin/bash
# shellcheck source=host/public-api.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/host/public-api.sh"

# Explicitly classify every public token. New commands cannot silently miss the
# lifecycle matrix; unrelated interfaces carry their reason for exclusion.
declare -A LIFECYCLE_COMMAND_SCOPE=(
    [up]=matrix [stop]=matrix [--clean]=matrix
    [init]=project-initialization [doctor]=editor-diagnostics
    [ssh-config]=editor-instructions [--uninstall]=installation
    [--version]=metadata [--help]=metadata [--config]=configuration-selection
)
LIFECYCLE_COMMANDS=()
initialize_lifecycle_commands() {
    local command
    # shellcheck disable=SC2034 # Passed by name to the mapping validator.
    local -a declarations=("${CLI_FLAGS_WITH_VALUES[@]}" "${CLI_FLAGS_WITHOUT_VALUES[@]}")
    public_api_validate_mapping 'lifecycle command scope' declarations LIFECYCLE_COMMAND_SCOPE
    LIFECYCLE_COMMANDS=()
    for command in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        [[ "${LIFECYCLE_COMMAND_SCOPE[$command]}" != matrix ]] || LIFECYCLE_COMMANDS+=("$command")
    done
}
initialize_lifecycle_commands

# A row is one job (three independent command fixtures). Each fault job keeps
# its healthy trace and every interruption in one worker's project identity.
lifecycle_jobs() {
    local row command policy
    while IFS= read -r row; do
        printf 'row.%s|row|%s\n' "${row%%|*}" "$row"
    done < <(lifecycle_matrix_rows)
    for command in "${LIFECYCLE_COMMANDS[@]}"; do
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
        for command in "${LIFECYCLE_COMMANDS[@]}"; do printf '%s.%s\n' "$row" "$command"; done
    done < <(lifecycle_matrix_rows)
    for command in "${LIFECYCLE_COMMANDS[@]}"; do
        for policy in false true; do
            [[ "$command:$policy" != up:true ]] || continue
            printf 'trace.%s.%s\n' "$command" "$policy"
        done
    done
    printf '%s\n' trace.up.none trace.up.new-ephemeral failed-new-container-cleanup
    for policy in false true; do
        for missing in false true; do printf 'failed-resume.%s.missing-proxy-%s\n' "$policy" "$missing"; done
        for command in "${LIFECYCLE_COMMANDS[@]}"; do printf 'home-inspection.%s.%s\n' "$policy" "$command"; done
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

# A stopped fixture's SSH port must not be borrowed for an outbound connection
# by another worker. Stay outside the kernel's ephemeral range and avoid ports
# already present in either IP socket table; never kill an unrelated listener.
lifecycle_fixture_port_available() {
    local port="$1" proc=${2:-/proc} lower upper extra hex
    local -a tables=("$proc/net/tcp")
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    ((port <= 65535)) || return 1
    read -r lower upper extra < "$proc/sys/net/ipv4/ip_local_port_range" || return 1
    [[ "$lower" =~ ^[1-9][0-9]{0,4}$ && "$upper" =~ ^[1-9][0-9]{0,4}$ && -z "$extra" ]] || return 1
    ((lower <= upper && upper <= 65535)) || return 1
    ((port < lower || port > upper)) || return 1
    if [[ -e "$proc/net/tcp6" ]]; then tables+=("$proc/net/tcp6"); fi
    hex=$(printf '%04X' "$port")
    awk -v port="$hex" '
        {n=split($2,address,":"); if (toupper(address[n])==port) occupied=1}
        END {exit occupied}
    ' "${tables[@]}"
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
    awk -v key="$key" '
        function group(k, a) {
            if (k ~ /^interrupt\./) { split(k,a,"."); return "interruptions " a[2] "/" a[3] }
            if (k ~ /^trace\./) return "discovery"
            if (k ~ /^(failed-|home-inspection\.)/) return "targeted failures"
            return "matrix"
        }
        group($0) == group(key) { total++; if ($0 == key) number=total }
        END { if (!number) exit 1; printf "CASE [%s %d/%d] %s\n",group(key),number,total,key }
    ' "${manifests[@]}"
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
    awk -F '|' '
        function group(k) {
            if (k ~ /^interrupt\./) return "interruptions"
            if (k ~ /^trace\./) return "discovery"
            if (k ~ /^(failed-|home-inspection\.)/) return "targeted"
            return "matrix"
        }
        FILENAME ~ /\/cases$/ { done[group($1)]++; finished++; next }
        { total[group($1)]++; expected++ }
        END {
            provisional=(done["discovery"] < total["discovery"])
            printf "Progress: %d/%d%s completed | matrix %d/%d | discovery %d/%d | interruptions %d/%d%s | targeted %d/%d\n", \
                finished,expected,(provisional ? " known" : ""),done["matrix"],total["matrix"], \
                done["discovery"],total["discovery"],done["interruptions"],total["interruptions"], \
                (provisional ? " known (discovering)" : ""),done["targeted"],total["targeted"]
        }
    ' "${completed[@]}" "${manifests[@]}"
}

# Startup sizing is a scheduling estimate, not a memory reservation. Use the
# process CPU affinity and visible cgroup-v2 ancestors, including containers
# whose cgroup namespace exposes their own limits at the mount root.
lifecycle_worker_resources() {
    local proc=${1:-/proc} cgroup=${2:-/sys/fs/cgroup} cpus=${3:-}
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
