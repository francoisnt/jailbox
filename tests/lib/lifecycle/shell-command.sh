#!/bin/bash
# Register the PTY's separate process group before entering the public CLI.
set -euo pipefail
ROOT="$1"
# shellcheck source=tests/lib/resource-ledger.sh
source "$ROOT/tests/lib/resource-ledger.sh"
LEDGER_FILE="$LIFECYCLE_POOL_LEDGER" ledger_record_owner "$$" || exit 1
exec "$ROOT/src/jailbox" shell
