#!/bin/bash
# Exact-name resource ledger for the e2e fixtures.
#
# jailbox resources carry no ownership label, so cleanup cannot discover what a
# test run created by enumerating Podman. Each run instead writes a ledger of
# the exact kind and name of every resource it may create, before creating it,
# and cleanup removes only those recorded objects. Nothing else on the host is
# ever a removal target: not the shared jailbox-wrapper-<stage> and
# jailbox-test-<stage> build caches, not a real project's sandbox — including
# the one this test may itself be running inside — and not debris left by runs
# that predate the ledger.
#
# The ledger lives outside the fixture directory it describes, so a run killed
# between creating resources and removing its temporary project is still
# recoverable. Entries survive until their resource is confirmed absent, which
# makes cleanup a retry rather than a single attempt.
#
# A run's own resources may be removed by that run at any time. Another run's
# resources are removed only once every process that owns them is known to have
# ended: each recorded pid must be gone or replaced (proved by comparing the
# process start time, not the pid alone), or the host must have rebooted since
# the run started. A run with any surviving owner, and any run whose liveness
# cannot be established, is preserved.
#
# The runner is not the only owner. Both gates fork background workers that can
# outlive it — a killed parent orphans them rather than stopping them — so each
# is recorded as an owner of the run and keeps it alive on its own.
#
# Sourced by the e2e scripts; it resolves its own dependencies from its path.
#
# Usage:
#   ledger_begin_run <tag>                  start this run's ledger
#   ledger_start_worker <command> [args...] start a registered background worker
#   ledger_record <kind> <name>             record one resource before creating it
#   ledger_record_project_resources <dir>   record a fixture project's whole set
#   ledger_prune_stale_runs                 clean up after runs that have ended
#   ledger_sweep_own_run                    clean up whatever this run left

# shellcheck source=src/host/core/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/host/core/project-id.sh"

LEDGER_DIR=""
LEDGER_FILE=""
LEDGER_WORKER_PID=""

# Containers are released before the volumes and networks they attach to, and
# images last, so no removal is blocked by another recorded object.
LEDGER_KIND_ORDER=(container volume network image)

# Ledger fields are whitespace-separated, so every recorded value is collapsed
# into a single token first.
ledger_token() {
    printf '%s' "$1" | tr -s '[:space:]' '_'
}

# An identifier for the current boot, so a run recorded before a restart is
# known to be over without inspecting any process. Empty when the host offers
# neither source, which reports uncertainty rather than a wrong answer.
ledger_boot_id() {
    local raw=""

    if { IFS= read -r raw < /proc/sys/kernel/random/boot_id; } 2>/dev/null; then
        [[ "$raw" != *[[:space:]]* ]] || return 0
        printf '%s\n' "$raw"
        return 0
    fi
    raw=$(sysctl -n kern.boottime 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    ledger_token "$raw"
}

# A process's start time, which distinguishes a live run from an unrelated
# process that later reused its pid. Fails when the process does not exist —
# and also on a host that can report neither, which ledger_run_state detects by
# probing its own pid. Status 2 distinguishes unreadable/malformed Linux data
# from a process directory that is no longer present (status 1).
ledger_process_start() {
    local raw
    local -a fields=()
    [[ "$1" =~ ^[0-9]+$ ]] || return 2

    if [[ -d /proc/self ]]; then
        if ! { raw=$(< "/proc/$1/stat"); } 2>/dev/null; then
            [[ ! -d "/proc/$1" ]] && return 1
            return 2
        fi
        # Field 2 is the executable name in parentheses and may itself contain
        # spaces and ')'. Everything after the final ') ' is whitespace-
        # separated, so starttime — field 22 overall — is field 20 there.
        [[ "$raw" = *') '* ]] || return 2
        read -r -a fields <<< "${raw##*') '}"
        raw=${fields[19]-}
        [[ "$raw" =~ ^[0-9]+$ ]] || return 2
        printf '%s\n' "$raw"
        return 0
    else
        # No procfs (macOS): ps reports the start time to the second, which
        # serves the same purpose.
        raw=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1
    fi
    [ -n "$raw" ] || return 1
    ledger_token "$raw"
}

# ended | active | unknown for one owner recorded as <pid> <start> under
# <boot>. Anything short of proof that the owner is gone reports uncertainty,
# and uncertainty preserves.
ledger_run_state() {
    case "$#" in
        3|5) ;;
        *) printf 'unknown\n'; printf 'ledger_run_state requires 3 or 5 arguments\n' >&2; return 2 ;;
    esac
    local pid="$1" start="$2" boot="$3"
    local current_boot current_start available status=0

    # A ledger scan supplies these shared facts once. Direct callers still get
    # a fresh check; there is no cache surviving a scan or cleanup operation.
    if [[ "$#" = 5 ]]; then
        current_boot="$4"; available="$5"
    else
        current_boot=$(ledger_boot_id) || current_boot=""
        available=false
        if ledger_process_start "$$" >/dev/null 2>&1; then available=true; fi
    fi

    # "unknown" is the sentinel ledger_begin_run writes when it could not read
    # the value, and an empty field is a malformed or truncated header. Either
    # way there is nothing to prove the owner ended.
    if [[ -z "$current_boot" || ! "$pid" =~ ^[0-9]+$ || "$boot" == unknown || -z "$boot" ||
        "$start" == unknown || -z "$start" ]]; then
        printf 'unknown\n'
        return 0
    fi
    if [[ "$boot" != "$current_boot" ]]; then
        printf 'ended\n'
        return 0
    fi
    # A start time this host cannot read even for the running process means the
    # mechanism is unavailable, not that the recorded owner is gone.
    if [[ "$available" != true ]]; then
        printf 'unknown\n'
        return 0
    fi
    current_start=$(ledger_process_start "$pid") || status=$?
    if [[ "$status" = 1 ]]; then
        printf 'ended\n'
    elif [[ "$status" != 0 || -z "$current_start" ]]; then
        printf 'unknown\n'
    elif [[ "$current_start" == "$start" ]]; then
        printf 'active\n'
    else
        printf 'ended\n'
    fi
}

# ended | active | unknown for a whole ledger: the runner recorded in the
# header plus every worker recorded since. A surviving owner outranks an
# uncertain one, and an uncertain one outranks an ended one, so a run is pruned
# only once every owner is provably gone.
ledger_file_state() {
    local file="$1" scope="${2:-all}"
    local header pid start boot result=ended kind current_boot available=false
    case "$scope" in all|owners) ;; *) return 1 ;; esac

    read -r header pid start boot < "$file" || return 1
    [[ "$header" == run ]] || return 1

    current_boot=$(ledger_boot_id) || current_boot=""
    if ledger_process_start "$$" >/dev/null 2>&1; then available=true; fi
    # The pool is checking its own children before its runner exits.
    if [[ "$scope" = all ]]; then
        result=$(ledger_run_state "$pid" "$start" "$boot" "$current_boot" "$available")
    fi
    [[ "$result" != active ]] || { printf 'active\n'; return 0; }

    while read -r kind pid start; do
        [[ "$kind" == owner ]] || continue
        case "$(ledger_run_state "$pid" "$start" "$boot" "$current_boot" "$available")" in
            active) printf 'active\n'; return 0 ;;
            unknown) result=unknown ;;
        esac
    done < "$file"

    printf '%s\n' "$result"
}

ledger_begin_run() {
    local tag="$1" start boot

    LEDGER_DIR="${JAILBOX_TEST_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jailbox-test-ledger}"
    mkdir -p "$LEDGER_DIR" || return 1
    start=$(ledger_process_start "$$") || start=""
    boot=$(ledger_boot_id)
    LEDGER_FILE="$LEDGER_DIR/$tag-$(date +%Y%m%d-%H%M%S)-$$.ledger"
    printf 'run %s %s %s\n' "$$" "${start:-unknown}" "${boot:-unknown}" > "$LEDGER_FILE"
}

# A background worker that owns some of this run's resources. Forked workers
# survive a killed parent, so each keeps the whole run alive until it exits.
# Called by ledger_start_worker before releasing the waiting worker.
ledger_record_owner() {
    local pid="$1" start

    if [[ -z "${LEDGER_FILE:-}" ]]; then
        echo "Error: resource ledger is not initialized" >&2
        return 1
    fi
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "Error: refusing to record owner pid '$pid'" >&2
        return 1
    fi
    # An unreadable start time must preserve the owner as uncertain.
    start=$(ledger_process_start "$pid") || start=unknown
    printf 'owner %s %s\n' "$pid" "$start" >> "$LEDGER_FILE"
}

# Registration is a handshake of a few milliseconds, so the wait is bounded well
# above any plausible one. Without a bound, a runner that died and had its pid
# reused would leave the child spinning forever on a `ready` that never comes,
# holding every file descriptor it inherited.
LEDGER_REGISTRATION_TIMEOUT_TICKS=200
LEDGER_REGISTRATION_TICK=0.05

# The worker cannot touch resources until its ownership has been recorded.
# If the runner exits during registration, the waiting worker exits too.
# Call from the runner shell; LEDGER_WORKER_PID is the child to wait for.
ledger_start_worker() {
    local barrier parent worker

    barrier=$(mktemp -d) || return 1
    parent=$BASHPID
    # An explicit stdin redirection prevents Bash from substituting /dev/null
    # for this asynchronous child when job control is disabled.
    (
        ticks=0
        while [ ! -f "$barrier/ready" ]; do
            if ! kill -0 "$parent" 2>/dev/null ||
                [ "$ticks" -ge "$LEDGER_REGISTRATION_TIMEOUT_TICKS" ]; then
                rm -rf -- "$barrier"
                exit 1
            fi
            ticks=$((ticks + 1))
            sleep "$LEDGER_REGISTRATION_TICK"
        done
        rm -rf -- "$barrier"
        "$@"
    ) <&0 &
    worker=$!
    # Returned to the sourcing runner so it can join this worker.
    # shellcheck disable=SC2034
    LEDGER_WORKER_PID=$worker
    if ! ledger_record_owner "$worker" || ! touch "$barrier/ready"; then
        kill "$worker" 2>/dev/null || true
        wait "$worker" 2>/dev/null || true
        rm -rf -- "$barrier"
        return 1
    fi
}

ledger_record() {
    local kind="$1" name="$2"

    if [[ -z "${LEDGER_FILE:-}" ]]; then
        echo "Error: resource ledger is not initialized" >&2
        return 1
    fi
    case "$kind" in
        container|volume|network|image) ;;
        *) echo "Error: unknown ledger resource kind '$kind'" >&2; return 1 ;;
    esac
    # Entries are whitespace-framed, and every derived jailbox name is a slug
    # and a hex hash. Refuse anything that would not round-trip.
    case "$name" in
        ""|*[[:space:]]*)
            echo "Error: refusing to record resource name '$name'" >&2
            return 1
            ;;
    esac
    printf '%s %s\n' "$kind" "$name" >> "$LEDGER_FILE"
}

# Every Podman object a jailbox launch of this fixture project can create.
# Their names derive from the project path, so they belong to this run alone
# and can never name a shared build cache or a real project's sandbox. Call
# this before the first launch of the project directory.
ledger_record_project_resources() {
    local project_dir="$1" prefix

    case "$project_dir" in
        # macOS resolves /tmp to /private/tmp when fixtures use pwd -P.
        /tmp/jailbox-editor-*|/tmp/jailbox-e2e-*|/private/tmp/jailbox-editor-*|/private/tmp/jailbox-e2e-*) ;;
        *)
            echo "Error: refusing to record resources for non-fixture project '$project_dir'" >&2
            return 1
            ;;
    esac
    prefix=$(jailbox_resource_prefix_for_path "$project_dir") || return 1

    ledger_record container "$prefix" || return 1
    ledger_record container "$prefix-proxy" || return 1
    ledger_record volume "$prefix-home" || return 1
    ledger_record network "$prefix-net" || return 1
    ledger_record network "$prefix-net-internal" || return 1
    ledger_record network "$prefix-net-external" || return 1
    # The proxy container and the proxy image share one name. Kinds are
    # recorded and removed independently, so neither depends on the other.
    ledger_record image "$prefix-proxy" || return 1
    ledger_record image "$prefix-image" || return 1
    ledger_record image "$prefix-dev" || return 1
}

# Confirmed absent, and only that: a probe that fails for any other reason
# keeps the entry so a later run retries it.
ledger_resource_absent() {
    local status=0

    case "$1" in
        container) podman container exists "$2" >/dev/null 2>&1 || status=$? ;;
        volume) podman volume exists "$2" >/dev/null 2>&1 || status=$? ;;
        network) podman network exists "$2" >/dev/null 2>&1 || status=$? ;;
        image) podman image exists "$2" >/dev/null 2>&1 || status=$? ;;
        *) return 1 ;;
    esac
    [[ "$status" -eq 1 ]]
}

ledger_remove_resource() {
    case "$1" in
        container) podman rm -f "$2" >/dev/null 2>&1 || true ;;
        volume) podman volume rm -f "$2" >/dev/null 2>&1 || true ;;
        network) podman network rm -f "$2" >/dev/null 2>&1 || true ;;
        image) podman rmi -f "$2" >/dev/null 2>&1 || true ;;
    esac
}

# Recorded resources, deduplicated. Matching on the kind keeps the header and
# the owner lines out by construction rather than by line number.
ledger_entries() {
    awk '$1 ~ /^(container|volume|network|image)$/ && NF == 2 && !seen[$0]++' "$1"
}

# Serialize cleanup in the shared ledger directory with a kernel lock. The
# descriptor, rather than a pid/start-time record, owns the lock: interrupted
# sweeps release it when their last inherited descriptor closes. There is no
# stale-lock deletion and no race between recovery and a new holder.
#
# Keep this one file permanently, including after all ledgers are gone.
# Unlinking it could let two processes lock different inodes at the same path.
# Linux provides flock; Perl's core flock supplies the same operation on macOS.
# Without either tool, preserve the ledger instead of sweeping without a lock.
ledger_lock_descriptor() {
    if command -v flock >/dev/null 2>&1; then
        flock -n "$1"
    elif command -v perl >/dev/null 2>&1; then
        perl -MFcntl=:flock -e '
            open(my $lock, ">&=$ARGV[0]") or die "open cleanup lock: $!\n";
            flock($lock, LOCK_EX | LOCK_NB) or exit 1;
        ' "$1"
    else
        echo "  Warning: test cleanup needs flock or Perl; preserving the ledger" >&2
        return 1
    fi
}

# Remove every recorded resource still present, then keep exactly the entries
# whose resources are not confirmed absent. The file is deleted once nothing is
# left to retry.
ledger_sweep_file() (
    local file="$1" label="$2" lock_fd

    # A subshell scopes the descriptor, including on errors. Descendant Podman
    # operations inherit it and keep the sweep locked if its shell is killed.
    exec {lock_fd}>>"$(dirname "$file")/.cleanup.lock" || return 1
    if ! ledger_lock_descriptor "$lock_fd"; then
        echo "  Could not lock cleanup for $(basename "$file"); leaving it for a later retry" >&2
        return 0
    fi
    # A preceding holder may already have finished this ledger while we were
    # inspecting its liveness.
    [[ -f "$file" ]] || return 0
    ledger_sweep_locked "$file" "$label"
)

ledger_sweep_locked() {
    local file="$1" label="$2"
    local pass_kind kind name tmp
    local -a remaining=()

    for pass_kind in "${LEDGER_KIND_ORDER[@]}"; do
        while read -r kind name; do
            [[ "$kind" == "$pass_kind" ]] || continue
            ledger_resource_absent "$kind" "$name" && continue
            echo "  Removing $label $kind $name"
            ledger_remove_resource "$kind" "$name"
        done < <(ledger_entries "$file")
    done

    while read -r kind name; do
        ledger_resource_absent "$kind" "$name" && continue
        remaining+=("$kind $name")
    done < <(ledger_entries "$file")

    if [[ -z "${remaining[*]-}" ]]; then
        rm -f "$file"
        return 0
    fi
    echo "  Keeping ${#remaining[@]} $label ledger entries for a later retry" >&2
    # A unique temporary plus an atomic rename, so that even an unserialized
    # rewrite degrades to last-writer-wins instead of one writer failing to
    # rename a temporary the other already consumed.
    if ! tmp=$(mktemp "$file.XXXXXX"); then
        echo "  Warning: could not rewrite $(basename "$file"); the next run retries every entry" >&2
        return 1
    fi
    if ! { head -n 1 "$file"; printf '%s\n' "${remaining[@]}"; } > "$tmp"; then
        echo "  Warning: could not rewrite $(basename "$file"); the next run retries every entry" >&2
        rm -f -- "$tmp"
        return 1
    fi
    mv -f "$tmp" "$file"
}

# Resources left by runs that have ended, including runs whose fixture
# directory is already gone. Runs that are still alive, and runs whose liveness
# cannot be established, are left completely alone.
#
# Debris from runs that predate the ledger is not discovered here and never
# will be: there is no label or name prefix to sweep. Inspect it by hand
# (`podman ps -a`, `podman volume ls`, `podman network ls`, `podman images`),
# look for jailbox-* names whose project directory no longer exists, and remove
# those exact names.
ledger_prune_stale_runs() {
    local file header pid start boot state

    [[ -n "${LEDGER_DIR:-}" && -d "$LEDGER_DIR" ]] || return 0
    for file in "$LEDGER_DIR"/*.ledger; do
        [[ -f "$file" ]] || continue
        [[ "$file" != "${LEDGER_FILE:-}" ]] || continue
        read -r header pid start boot < "$file" || continue
        [[ "$header" == run ]] || continue
        state=$(ledger_file_state "$file") || continue
        # Cleanup bookkeeping never fails a gate: the resources are already
        # removed, and a ledger left untrimmed only costs the next run a
        # redundant retry.
        case "$state" in
            ended) ledger_sweep_file "$file" "stale test" || true ;;
            *) echo "  Preserving the resources of $state test run $pid" ;;
        esac
    done
}

ledger_sweep_own_run() {
    [[ -n "${LEDGER_FILE:-}" && -f "$LEDGER_FILE" ]] || return 0
    ledger_sweep_file "$LEDGER_FILE" "leftover" || true
}
