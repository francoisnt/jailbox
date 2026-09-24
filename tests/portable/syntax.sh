#!/bin/bash
# Shared by development checks and the full distribution gate.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
for script in src/jailbox src/public-api.sh src/install.sh tests/run; do
    bash -n "$script"
done
scripts=$(find src/host scripts tests -type f -name '*.sh' -print | LC_ALL=C sort)
while IFS= read -r script; do
    [[ -z "$script" ]] || bash -n "$script"
done <<< "$scripts"
# shellcheck source=scripts/lib/container-shells.sh
source scripts/lib/container-shells.sh
check_container_syntax src
