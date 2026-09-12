#!/bin/bash
# Bounded, independently owned lifecycle workers. Requires wrapper preparation.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
test_log_entrypoint "$ROOT/tests/integration/lifecycle-state.sh" "$@"
# shellcheck source=tests/lib/resource-ledger.sh
source "$ROOT/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"

die() { printf 'FAIL [lifecycle-pool]: %s\n' "$*" >&2; exit 1; }
if [[ -n ${JAILBOX_LIFECYCLE_JOBS:-} ]]; then
    WORKERS=$JAILBOX_LIFECYCLE_JOBS
    WORKER_SELECTION="explicit override"
else
    IFS="|" read -r AVAILABLE_CPUS AVAILABLE_MEMORY < <(lifecycle_worker_resources /proc /sys/fs/cgroup)
    WORKERS=$(lifecycle_worker_budget "$AVAILABLE_CPUS" "$AVAILABLE_MEMORY")
    WORKER_SELECTION="auto: $AVAILABLE_CPUS CPUs, $((AVAILABLE_MEMORY / 1024)) MiB available; budget 2 CPUs + 2048 MiB per worker, reserve 1024 MiB"
fi
[[ "$WORKERS" =~ ^([1-9]|1[0-6])$ ]] || die 'JAILBOX_LIFECYCLE_JOBS must be 1 through 16'
for tool in podman ssh ssh-keygen git setsid; do
    command -v "$tool" >/dev/null || die "$tool is required"
done
[[ $(uname -s) = Linux ]] || die 'Linux is required'
podman image exists jailbox-test-debian || die 'run wrapper-images.sh first'
RUN="$ROOT/testlog/lifecycle-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUN/claims" "$RUN/done"
lifecycle_jobs > "$RUN/catalog"
TIMINGS=${JAILBOX_LIFECYCLE_TIMINGS:-/dev/null}
[[ -r "$TIMINGS" ]] || die "cannot read timing history: $TIMINGS"
lifecycle_order_jobs "$RUN/catalog" "$TIMINGS" > "$RUN/jobs"
lifecycle_fixed_cases > "$RUN/expected-fixed"
export JAILBOX_TEST_LEDGER_DIR="${JAILBOX_TEST_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jailbox-test-ledger}"
ledger_begin_run lifecycle-pool
export LIFECYCLE_POOL_LEDGER="$LEDGER_FILE"
ledger_prune_stale_runs

declare -a worker_pids=() fixtures=() worker_logs=()
declare -A used_ports=() used_subnets=()
pool_cleanup() {
    local result=$? pid log child_ledger fixture safe=true kind start boot
    trap - EXIT
    for pid in "${worker_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${worker_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    # Also covers cancellation between registration and recording the PID in
    # worker_pids, and CLIs orphaned by an unexpectedly killed worker.
    read -r kind pid start boot < "$LEDGER_FILE"
    while read -r kind pid start; do
        [[ "$kind" = owner ]] || continue
        if [[ $(ledger_run_state "$pid" "$start" "$boot") != ended ]]; then safe=false; fi
    done < "$LEDGER_FILE"
    for log in "${worker_logs[@]}"; do
        [[ -f "$log/ledger" ]] || continue
        IFS= read -r child_ledger < "$log/ledger"
        if [[ -f "$child_ledger" && $(ledger_file_state "$child_ledger") != ended ]]; then safe=false; fi
    done
    if [[ "$safe" = true ]]; then
        ledger_sweep_own_run
        for log in "${worker_logs[@]}"; do
            [[ -f "$log/ledger" ]] || continue
            IFS= read -r child_ledger < "$log/ledger"
            ledger_sweep_file "$child_ledger" 'lifecycle worker' || result=1
        done
        if [[ ! -f "$LEDGER_FILE" ]]; then
            for fixture in "${fixtures[@]}"; do rm -rf -- "$fixture"; done
        else
            result=1
        fi
    else
        printf 'A lifecycle CLI is still active; preserving its resources and ledger.\n' >&2
        result=1
    fi
    exit "$result"
}
trap pool_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Reserve distinct derived SSH ports and disjoint first/fallback subnet pairs
# within this pool. Podman still owns detection of unrelated host collisions.
for ((slot=1; slot<=WORKERS; slot++)); do
    for ((attempt=1; ; attempt++)); do
        [[ "$attempt" -le 100 ]] || die 'could not allocate distinct worker identities with free SSH ports outside the host ephemeral range'
        fixture=$(mktemp -d /tmp/jailbox-e2e-lifecycle.XXXXXXXX)
        fixture=$(cd "$fixture" && pwd -P)
        offset=$(jailbox_project_hash_port_offset "$(jailbox_project_hash_for_path "$fixture/project")")
        subnet=$((offset % 200))
        fallback=$(((subnet + 7) % 200))
        if [[ -z ${used_ports[$offset]-} && -z ${used_subnets[$subnet]-} && -z ${used_subnets[$fallback]-} ]] &&
            lifecycle_fixture_port_available "$((49152 + offset))"; then break; fi
        rm -rf -- "$fixture"
    done
    used_ports[$offset]=true
    used_subnets[$subnet]=true
    used_subnets[$fallback]=true
    fixtures+=("$fixture")
    log="$RUN/worker-$slot"
    mkdir -p "$log"
    worker_logs+=("$log")
    ledger_record_project_resources "$fixture/project"
    prefix=$(jailbox_resource_prefix_for_path "$fixture/project")
    ledger_record network "$prefix-fixture-extra"
done

launch_worker() { exec bash "$ROOT/tests/lib/lifecycle-worker.sh" "$@"; }
printf 'Lifecycle: %s jobs, %s workers; logs: %s\n' "$(wc -l < "$RUN/jobs")" "$WORKERS" "$RUN"
printf 'Worker selection: %s\n' "$WORKER_SELECTION"
lifecycle_progress "$RUN"
for ((slot=0; slot<WORKERS; slot++)); do
    ledger_start_worker launch_worker "$RUN" "${worker_logs[$slot]}" "${fixtures[$slot]}" || die 'could not register worker'
    worker_pids+=("$LEDGER_WORKER_PID")
done
result=0
for pid in "${worker_pids[@]}"; do wait "$pid" || result=1; done
worker_pids=()
# Per-job files are written only after success; retain timings even on failure.
find "$RUN/done" -type f -exec cat {} + | LC_ALL=C sort > "$RUN/timings"
cut -d '|' -f1 "$RUN/catalog" | LC_ALL=C sort > "$RUN/expected-jobs"
cut -d '|' -f1 "$RUN/timings" | LC_ALL=C sort > "$RUN/completed-jobs"
cmp -s "$RUN/expected-jobs" "$RUN/completed-jobs" || result=1
cat "$RUN/expected-fixed" "$RUN"/worker-*/expected-faults | LC_ALL=C sort > "$RUN/expected-cases" || result=1
cat "$RUN"/worker-*/cases | LC_ALL=C sort > "$RUN/case-timings" || result=1
cut -d '|' -f1 "$RUN/case-timings" | LC_ALL=C sort > "$RUN/completed-cases"
cmp -s "$RUN/expected-cases" "$RUN/completed-cases" || result=1
printf 'Lifecycle: %s/%s cases completed; timings: %s/timings\n' \
    "$(wc -l < "$RUN/completed-cases")" "$(wc -l < "$RUN/expected-cases")" "$RUN"
[[ "$result" = 0 ]] || die "worker failure or incomplete coverage; inspect $RUN"
printf 'Lifecycle constructed-state matrix passed; logs: %s\n' "$RUN"
