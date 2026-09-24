#!/bin/bash
set -euo pipefail
JAILBOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
# shellcheck source=tests/lib/stage-pool.sh
source "$JAILBOX_DIR/tests/lib/stage-pool.sh"
STAGE_WORKER_VARIABLES=""
if [[ ${STAGE_TEST_LEDGER:-0} = 1 ]]; then
    # shellcheck source=tests/lib/resource-ledger.sh
    source "$JAILBOX_DIR/tests/lib/resource-ledger.sh"
    STAGE_WORKER_VARIABLES="LEDGER_DIR LEDGER_FILE"
fi
worker_tool_budget() { printf '%s\n' "$STAGE_TEST_WORKERS"; }
cleanup_fixture_stage() {
    local status=$?
    # Cleanup needs a caller-owned dependency even after cancellation. The
    # delay exposes premature parent cleanup instead of merely checking markers.
    sleep 0.05
    [[ -f "$fixture_logs/dependency" ]] || { touch "$fixture_logs/dependency-lost"; exit 98; }
    test_phase_end "$status"
    printf 'fixture cleanup finished\n'
    touch "$fixture_logs/$fixture_name.cleaned"
    [[ "$fixture_name" != cleanup-failure ]] || exit 23
}
fixture_stage() {
    fixture_name=$1 fixture_logs=$2
    local stage=$1 logs=$2
    trap cleanup_fixture_stage EXIT
    test_phase_begin fixture
    [[ ${JAILBOX_TEST_PROGRESS_TERMINAL:-} = false ]] || return 1
    if [[ ${STAGE_TEST_LEDGER:-0} = 1 ]]; then
        grep -q "^owner $BASHPID " "$LEDGER_FILE" || return 1
    fi
    touch "$logs/$stage.started"
    while [[ ! -f "$logs/$stage.release" ]]; do sleep 0.05; done
    case "$stage" in
        crash) false; touch "$logs/should-not-exist" ;;
        assertion) printf '1 1\n' > "$logs/$stage.counts" ;;
        bad-counts) printf 'invalid nope\n' > "$logs/$stage.counts" ;;
        missing-counts) : ;;
        failed-exit) printf '2 0\n' > "$logs/$stage.counts"; return 42 ;;
        *) printf '1 0\n' > "$logs/$stage.counts" ;;
    esac
}
cleanup_fixture_pool() {
    local status=$?
    trap - EXIT
    trap '' INT TERM HUP
    stage_pool_cancel || { ((status != 0)) || status=1; }
    rm -f "$logs/dependency"
    printf '%s\n' "$status" > "$logs/parent.cleaned"
    exit "$status"
}
if [[ ${BASH_SOURCE[0]} = "$0" ]]; then
    logs=$1; callback=$2; shift 2
    trap cleanup_fixture_pool EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    touch "$logs/dependency"
    if [[ ${STAGE_TEST_LEDGER:-0} = 1 ]]; then
        JAILBOX_TEST_LEDGER_DIR="$logs/ledger" ledger_begin_run fixture
    fi
    if [[ ${STAGE_TEST_LAUNCH_FAILURE:-0} = 1 ]]; then
        # shellcheck disable=SC2329 # Process-pool launch callback.
        stage_pool_launch() { return 42; }
    elif [[ ${STAGE_TEST_REGISTRATION_SIGNAL:-0} != 0 ]]; then
        # shellcheck disable=SC2329 # Process-pool launch callback.
        stage_pool_launch() {
            ledger_start_worker exec bash "$JAILBOX_DIR/tests/lib/stage-log.sh" \
                "$stage_runner" "$stage_logs/worker-context" "$stage_callback" \
                "$1" "$stage_logs" "$2" "$stage_total" > "$stage_logs/$1.log" 2>&1 || return 1
            while [[ ! -f "$stage_logs/$1.started" ]]; do sleep 0.01; done
            # Interrupt before transferring LEDGER_WORKER_PID to the pool.
            kill -"$STAGE_TEST_REGISTRATION_SIGNAL" "$BASHPID"
        }
    fi
    before=$(trap -p EXIT INT TERM HUP)
    result=0
    run_stage_pool runtime fixture/explicit "$logs" "$callback" "${BASH_SOURCE[0]}" "$@" || result=$?
    [[ $(trap -p EXIT INT TERM HUP) = "$before" ]] || exit 97
    printf '%s %s\n' "$STAGE_PASSED" "$STAGE_FAILED" > "$logs/totals"
    printf '%s\n' "${STAGE_FAILED_STAGES[@]}" > "$logs/failed-stages"
    exit "$result"
fi
