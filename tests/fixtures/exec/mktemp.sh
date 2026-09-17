#!/bin/bash
set -euo pipefail
[[ $(umask) = 0077 ]] || exit 99
[[ ${EXEC_FAIL_TEMP:-false} != true ]] || exit 42
if [[ -n ${EXEC_INTERRUPT_TEMP:-} ]]; then
    "$EXEC_REAL_MKTEMP" "$@"
    kill -s "$EXEC_INTERRUPT_TEMP" "$PPID"
    exit 0
fi
exec "$EXEC_REAL_MKTEMP" "$@"
