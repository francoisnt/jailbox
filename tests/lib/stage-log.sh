#!/bin/bash
# Keep a stage's log formatter joined without changing the worker's shell state.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
worker_pid="" formatter_pid="" log_fd=""
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
finish_stage_log() {
    local status=$?
    trap - EXIT
    trap '' INT TERM HUP
    if [[ -n "$worker_pid" ]]; then
        kill -TERM "$worker_pid" 2>/dev/null || true
        wait "$worker_pid" 2>/dev/null || true
    fi
    if [[ -n "$log_fd" ]]; then exec {log_fd}>&-; fi
    if [[ -n "$formatter_pid" ]]; then wait "$formatter_pid" || status=1; fi
    exit "$status"
}
trap finish_stage_log EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
exec {log_fd}> >(test_timestamp_stream)
formatter_pid=$!
bash "$ROOT/tests/lib/stage-worker.sh" "$@" >&"$log_fd" 2>&1 {log_fd}>&- &
worker_pid=$!
status=0
wait "$worker_pid" || status=$?
worker_pid=""
exit "$status"
