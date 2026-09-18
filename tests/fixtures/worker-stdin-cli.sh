#!/bin/bash
# Stand in only for the CLI process after the real ledger/launcher boundary.
set -euo pipefail
grep -Eq "^owner $$ " "$LIFECYCLE_POOL_LEDGER"
if [[ "$1" = shell ]]; then
    [[ -t 0 && -t 1 ]] || exit 92
    exec bash --noprofile --norc -il
fi
[[ "$1" = exec ]]
shift
if [[ ${1:-} = -- ]]; then shift; fi
exec "$@"
