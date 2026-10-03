#!/bin/bash
set -euo pipefail
JAILBOX_DIR=$1
SCRIPT_DIR=$2/tests
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
# shellcheck source=tests/lib/portable-pool.sh
source "$JAILBOX_DIR/tests/lib/portable-pool.sh"
# The pool owns cancellation in its foreground subshell. Keep this wrapper
# alive until that subshell has joined its supervisors and finished cleanup;
# otherwise waiting for this PID only observes the wrapper's early death.
trap ':' HUP INT TERM
portable_suite_pool "$2/run" "$3"
