#!/bin/bash
set -euo pipefail
source "$1/tests/lib/logging.sh"
test_log_entrypoint "$0" "$@"
trap 'echo cleanup >&2' EXIT
cat
false
echo unreachable
