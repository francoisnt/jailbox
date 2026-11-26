#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tests/ci" "$tmp/tests/lib"
cp "$ROOT/tests/ci/capture-step.sh" "$tmp/tests/ci/"
cp "$ROOT/tests/lib/logging.sh" "$tmp/tests/lib/"
capture="$tmp/tests/ci/capture-step.sh"

for gate in lint portable runtime matrix editor; do
    status=0
    bash "$capture" "$gate" setup bash -c 'printf "setup stdout\n"; printf "setup stderr\n" >&2; exit 42' \
        > "$tmp/console" || status=$?
    [[ "$status" = 42 ]]
    log="$tmp/testlog/ci-setup/$gate/setup.log"
    cmp "$tmp/console" "$log"
    grep -Fq 'setup stdout' "$log"
    grep -Fq 'setup stderr' "$log"
done

# Inline workflow programs execute with pipefail and retain their diagnostics.
status=0
bash "$capture" portable shellcheck > "$tmp/console" <<'SCRIPT' || status=$?
printf 'installing\n'
false | cat
printf 'unexpected continuation\n'
SCRIPT
[[ "$status" = 1 ]]
cmp "$tmp/console" "$tmp/testlog/ci-setup/portable/shellcheck.log"
grep -Fq installing "$tmp/console"
if grep -Fq 'unexpected continuation' "$tmp/console"; then exit 1; fi
[[ -f "$tmp/testlog/ci-setup/portable/setup.log" ]]
