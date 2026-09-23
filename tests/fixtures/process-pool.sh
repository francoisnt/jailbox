#!/bin/bash
# Exercise the shared pool with commands supplied as counted NUL records.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/process-pool.sh
source "$ROOT/scripts/lib/process-pool.sh"
cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    process_pool_cancel 5 || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM
report() { printf 'pool: %s: status %s, %ss\n' "$1" "$2" "$3"; }
launch() {
    "$@" &
    PROCESS_POOL_LAUNCHED_PID=$!
}
process_pool_init "${POOL_TEST_LIMIT:-2}" report
while IFS= read -r -d '' label; do
    IFS= read -r -d '' count
    [[ "$count" =~ ^[1-9][0-9]*$ ]]
    args=()
    for ((index=0; index<count; index++)); do
        IFS= read -r -d '' argument
        args+=("$argument")
    done
    process_pool_submit "$label" launch "${args[@]}"
done
process_pool_wait
