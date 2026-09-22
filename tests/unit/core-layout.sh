#!/bin/bash
# New core modules and command handlers cannot escape ownership/install checks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/public-api.sh
source "$ROOT/src/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$ROOT/src/host/api-support.sh"
initialize_public_api_lookups
# shellcheck source=src/host/cli.sh
source "$ROOT/src/host/cli.sh"
validate_cli_implementation
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
for command in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
    printf '%s\t%s\n' "$command" "${CLI_COMMAND_HANDLERS[$command]}"
done > "$tmp/handlers"
python3 "$ROOT/tests/lib/check-core-layout.py" "$ROOT" < "$tmp/handlers"
mkdir -p "$tmp/tree/src/host"
cp -R "$ROOT/src/host/core" "$tmp/tree/src/host/"
cp "$ROOT/src/"{jailbox,install.sh} "$tmp/tree/src/"
check_refusal() {
    if python3 "$ROOT/tests/lib/check-core-layout.py" "$tmp/tree" < "$tmp/handlers" > "$tmp/error" 2>&1; then
        printf 'FAIL: incomplete core contract accepted\n' >&2; exit 1
    fi
    grep -Fq "$1" "$tmp/error"
}
printf 'future_check() { :; }\n' > "$tmp/tree/src/host/core/resources/future.sh"
check_refusal 'installer core inventory mismatch'
rm "$tmp/tree/src/host/core/resources/future.sh"
printf '\ninvalid_resource() { run_up; }\n' >> "$tmp/tree/src/host/core/resources/container.sh"
check_refusal 'resource calls public handler'
cp "$ROOT/src/host/core/resources/container.sh" "$tmp/tree/src/host/core/resources/container.sh"
printf '\nfuture_handler() { :; }\n' >> "$tmp/tree/src/host/core/resources/container.sh"
printf 'future\tfuture_handler\n' >> "$tmp/handlers"
check_refusal 'command handler outside commands'
printf 'PASS: missing inventory and misplaced command negative controls\n'
