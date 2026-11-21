#!/bin/bash
set -euo pipefail
printf 'cHJpbnRmAGV4ZWN1dGVkAA==\n'
if [[ ${EXEC_INTERRUPT_ENCODE:-false} = true ]]; then kill -TERM "$PPID"; fi
exit 42
