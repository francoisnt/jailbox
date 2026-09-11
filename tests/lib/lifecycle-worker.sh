#!/bin/bash
# Internal worker for the lifecycle runtime suite; not a separate test gate.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
# shellcheck source=tests/lib/resource-ledger.sh
source "$ROOT/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/lifecycle-assertions.sh
source "$ROOT/tests/lib/lifecycle-assertions.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
# shellcheck source=tests/lib/lifecycle-fixture.sh
source "$ROOT/tests/lib/lifecycle-fixture.sh"
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
# shellcheck source=tests/lib/lifecycle-runtime-faults.sh
source "$ROOT/tests/lib/lifecycle-runtime-faults.sh"

matrix_die() { printf 'FAIL [%s]: %s\n' "${CASE_KEY:-setup}" "$*" >&2; exit 1; }
RUN="$1"
WORKER_LOG="$2"
ACTIVE_PID=""
exec {console_fd}>&1
exec > >(test_timestamp_stream | tee "$WORKER_LOG/worker.log") 2>&1
logger_pid=$!
worker_cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$ACTIVE_PID" ]]; then
        kill -KILL -- "-$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
    fi
    # The parent sweeps images after every worker has stopped. Image layers can
    # be shared even though all worker tags and mutable resources are distinct.
    exec >&"$console_fd" 2>&1
    exec {console_fd}>&-
    wait "$logger_pid" || result=1
    exit "$result"
}
trap worker_cleanup EXIT
trap 'exit 1' HUP INT TERM
lifecycle_setup "$3" "$WORKER_LOG"
: > "$LOG/cases"
: > "$LOG/expected-faults"
lifecycle_run_queue "$RUN" lifecycle_dispatch_job </dev/null
