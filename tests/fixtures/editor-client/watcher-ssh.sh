#!/bin/bash
set -euo pipefail
if [[ -n ${FAKE_TRACE:-} ]]; then printf 'watcher-check\n' >> "$FAKE_TRACE"; fi
if [[ -n ${WATCHER_ARGS:-} ]]; then printf '%s\n' "$@" > "$WATCHER_ARGS"; fi
if [[ -n ${WATCHER_HANG_PID:-} ]]; then
    printf '%s\n' "$$" > "$WATCHER_HANG_PID"
    trap '' TERM
    exec sleep 60
fi
printf '%s\n' "${WATCHER_LIMIT-524288}"
exit "${WATCHER_STATUS:-0}"
