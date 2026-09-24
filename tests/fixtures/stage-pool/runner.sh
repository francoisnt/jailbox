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
    test_phase_end "$status"
    printf 'fixture cleanup finished\n'
    touch "$fixture_logs/$fixture_name.cleaned"
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
        *) printf '1 0\n' > "$logs/$stage.counts" ;;
    esac
}
if [[ ${BASH_SOURCE[0]} = "$0" ]]; then
    logs=$1; callback=$2; shift 2
    if [[ ${STAGE_TEST_LEDGER:-0} = 1 ]]; then
        JAILBOX_TEST_LEDGER_DIR="$logs/ledger" ledger_begin_run fixture
    fi
    trap 'touch "$logs/parent.cleaned"' EXIT
    run_stage_pool runtime "$logs" "$callback" "${BASH_SOURCE[0]}" "$@"
fi
