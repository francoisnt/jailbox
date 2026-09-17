#!/bin/bash
# Stand in only for the CLI process after the real ledger/launcher boundary.
set -euo pipefail
grep -Eq "^owner $$ " "$LIFECYCLE_POOL_LEDGER"
[[ "$1" = exec ]]
shift
if [[ ${1:-} = -- ]]; then shift; fi
exec "$@"
