#!/bin/bash
set -euo pipefail
JAILBOX_DIR=$1
SCRIPT_DIR=$2/tests
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
# shellcheck source=tests/lib/portable-pool.sh
source "$JAILBOX_DIR/tests/lib/portable-pool.sh"
portable_unit_pool "$2/run" "$3"
