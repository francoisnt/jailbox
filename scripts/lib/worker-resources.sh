#!/bin/bash
# Resource detection shared by repository worker pools. Memory is in KiB.
# Startup sizing is a scheduling estimate, not a memory reservation. Use the
# process CPU affinity and visible cgroup-v2 ancestors, including containers
# whose cgroup namespace exposes their own limits at the mount root.
worker_linux_resources() {
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

worker_macos_memory() {
    # vm_stat reports page counts with trailing periods; active/wired pages
    # are deliberately excluded from the available-memory estimate.
    awk '
        /page size of [0-9]+ bytes/ { for (i=1; i<NF; i++) if ($i == "of") size=$(i+1) }
        /^Pages (free|inactive|speculative):/ {
            value=$NF; sub(/\.$/, "", value)
            if (value !~ /^[0-9]+$/) bad=1
            pages+=value; found++
        }
        END { if (!bad && found == 3 && size > 0) printf "%.0f\n", pages * size / 1024; else print 0 }
    '
}

worker_host_resources() {
    local platform cpus memory pages
    platform=$(uname -s) || { printf '1|0\n'; return; }
    case "$platform" in
        Linux) worker_linux_resources /proc /sys/fs/cgroup ;;
        Darwin)
            cpus=$(sysctl -n hw.logicalcpu 2>/dev/null) || cpus=1
            [[ "$cpus" =~ ^[1-9][0-9]{0,5}$ ]] || cpus=1
            pages=$(vm_stat 2>/dev/null) || pages=""
            memory=$(worker_macos_memory <<< "$pages") || memory=0
            printf '%s|%s\n' "$cpus" "$memory"
            ;;
        *) printf '1|0\n' ;;
    esac
}

# Scheduling allowances, not enforced CPU/RAM limits. Unknown memory falls
# back to a single worker. Callers select costs for their complete workload.
worker_budget() {
    local cpus=$1 memory=$2 cpu_cost=$3 memory_cost=$4 reserve=$5 maximum=$6 value workers by_memory
    for value in "$cpus" "$cpu_cost" "$memory_cost" "$maximum"; do
        [[ "$value" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
    done
    for value in "$memory" "$reserve"; do
        [[ "$value" =~ ^(0|[1-9][0-9]{0,14})$ ]] || return 1
    done
    workers=$((cpus / cpu_cost))
    by_memory=$(((memory - reserve) / memory_cost))
    ((by_memory >= workers)) || workers=$by_memory
    ((workers <= maximum)) || workers=$maximum
    ((workers >= 1)) || workers=1
    printf '%s\n' "$workers"
}

worker_tool_budget() {
    local resources cpus memory cost workers cpu_cost=1 reserve=524288 limit=${JAILBOX_TEST_JOB_LIMIT:-16}
    [[ "$limit" =~ ^([1-9]|1[0-6])$ ]] || {
        printf 'JAILBOX_TEST_JOB_LIMIT must be 1 through 16\n' >&2; return 1;
    }
    case "$1" in
        lint) cost=1572864 ;; # 1.5 GiB; sampled ShellCheck peak was 1.24 GiB.
        portable) cost=262144 ;; # 256 MiB for an isolated unit-suite process tree.
        runtime) cost=2097152; cpu_cost=2; reserve=1048576 ;;
        editor) cost=4194304; cpu_cost=2; reserve=1048576 ;;
        *) return 1 ;;
    esac
    resources=$(worker_host_resources) || return 1
    IFS='|' read -r cpus memory <<< "$resources"
    workers=$(worker_budget "$cpus" "$memory" "$cpu_cost" "$cost" "$reserve" "$limit") || return 1
    printf '%s\n' "$workers"
}
