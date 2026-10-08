#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
# shellcheck source=tests/lib/lifecycle-logging.sh
source "$ROOT/tests/lib/lifecycle-logging.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
LOG=$fixture CASE_KEY=interrupt.clean
mkdir "$LOG/$CASE_KEY"

# A failed relaunch retains earlier cleanup output and its own exit status.
lifecycle_capture printf 'setup\n'
setup_log=$LIFECYCLE_COMMAND_LOG
lifecycle_capture printf 'removed image abc123\n'
cleanup_log=$LIFECYCLE_COMMAND_LOG
failure() { printf 'image not known\n'; return 42; }
result=0
lifecycle_capture failure || result=$?
[[ $result == 42 ]]
grep -q 'setup$' "$setup_log"
grep -q 'removed image abc123$' "$cleanup_log"
grep -q 'image not known$' "$LIFECYCLE_COMMAND_LOG"
cmp "$LOG/$CASE_KEY/command" "$LIFECYCLE_COMMAND_LOG"
grep -q $'exit=42$' "$LOG/command-index.tsv"

# A second case keeps separate files, and every index entry resolves from the worker.
CASE_KEY=running.up
mkdir "$LOG/$CASE_KEY"
lifecycle_capture printf 'second case\n'
grep -q 'image not known$' "$LOG/interrupt.clean/command"
grep -q 'second case$' "$LOG/running.up/command"
while IFS=$'\t' read -r path detail; do
    [[ -f "$LOG/$path" && "$path" == */command.* && -n "$detail" ]]
done < "$LOG/command-index.tsv"
[[ ! -e "$LOG/interrupt.clean.command" ]]

printf 'PASS: lifecycle logs retain earlier output and command exit statuses\n'
