#!/bin/bash
set -euo pipefail
printf 'printf\0executed\0'
if [[ ${EXEC_INTERRUPT_DECODE:-false} = true ]]; then kill -TERM "$PPID"; fi
exit 42
