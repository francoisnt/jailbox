#!/bin/bash
set -euo pipefail
[[ $# == 1 && $1 == validate ]] || exit 97
printf '%s\n' "$1" >> "$FRONTEND_TEST_CALLS"
env -0 > "$FRONTEND_TEST_ENV"
if [[ -n ${FRONTEND_TEST_STDOUT:-} ]]; then printf '%s\n' "$FRONTEND_TEST_STDOUT"; fi
exit "${FRONTEND_TEST_STATUS:-0}"
