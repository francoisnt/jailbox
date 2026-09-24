#!/bin/bash
# Internal worker entrypoint: load a runner without starting its coordinator.
set -euo pipefail
runner=$1
context=$2
callback=$3
shift 3
# shellcheck disable=SC1090 # The coordinator supplies its own runner path.
source "$runner"
while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    [[ " $STAGE_WORKER_VARIABLES " = *" $name "* ]] || exit 1
    printf -v "$name" '%s' "$value"
done < "$context"
# The log supervisor is registered too; record the actual resource owner so
# an unexpectedly killed supervisor cannot make a live worker look stale.
if declare -F ledger_record_owner >/dev/null; then
    ledger_record_owner "$BASHPID" || exit 1
fi
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
TEST_PHASE_LOG="$2/$1.phases"
# Stage output is captured even when the coordinator owns a terminal.
export JAILBOX_TEST_PROGRESS_TERMINAL=false
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$callback" "$@"
