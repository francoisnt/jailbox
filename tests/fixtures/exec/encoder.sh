#!/bin/bash
set -euo pipefail
[[ "${1:-} ${2:-}" = 'dev encode' ]] || exit 99
printf 'cHJpbnRmAGV4ZWN1dGVkAA=='
printf 'Error: could not encode %s arguments\n' "$3" >&2
if [[ ${EXEC_INTERRUPT_ENCODE:-false} = true ]]; then kill -TERM "$PPID"; fi
exit 42
