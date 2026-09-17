#!/bin/bash
set -euo pipefail
if [[ ${EXEC_FAIL_CLEANUP:-false} = true ]]; then exit 42; fi
exec "$EXEC_REAL_RM" "$@"
