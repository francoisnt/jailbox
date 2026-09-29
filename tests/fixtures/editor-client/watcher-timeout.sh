#!/bin/bash
set -euo pipefail
[[ ${1:-} == --kill-after=1s && ${2:-} == 5s && ${3:-} == ssh ]] || exit 1
if [[ -n ${WATCHER_HANG_PID:-} ]]; then
    shift 2
    set -- --kill-after=0.2s 0.5s "$@"
    printf '%s\n' "$@" > "$WATCHER_HANG_PID.timeout-args"
fi
exec "$WATCHER_TIMEOUT_REAL" "$@"
