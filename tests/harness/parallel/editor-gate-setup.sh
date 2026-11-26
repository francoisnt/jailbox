#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tests/ci" "$tmp/tests/lib" "$tmp/scripts"
cp "$ROOT/tests/ci/editor-gate.sh" "$tmp/tests/ci/"
cp "$ROOT/tests/lib/logging.sh" "$tmp/tests/lib/"
cat > "$tmp/scripts/apply-updates.sh" <<'UPDATE'
#!/bin/bash
printf 'Update: %s\n' "$*"
exit "${FIXTURE_UPDATE_STATUS:-0}"
UPDATE
cat > "$tmp/tests/ci/setup-linux.sh" <<'SETUP'
#!/bin/bash
printf 'Setup: %s\n' "$*"
printf 'Setup diagnostic\n' >&2
exit "${FIXTURE_SETUP_STATUS:-0}"
SETUP

run_setup() {
    bash "$tmp/tests/ci/editor-gate.sh" setup CODE_VERSION=fixture
}
log="$tmp/testlog/ci-setup/editor/setup.log"
run_setup > "$tmp/console"
cmp "$tmp/console" "$log"
grep -Fq 'Update: CODE_VERSION=fixture' "$log"
grep -Fq 'Setup: --with-editors' "$log"
grep -Fq 'Setup diagnostic' "$log"

status=0
FIXTURE_SETUP_STATUS=42 run_setup > "$tmp/console" || status=$?
[[ "$status" = 42 ]]
cmp "$tmp/console" "$log"
grep -Fq 'Setup diagnostic' "$log"

status=0
FIXTURE_UPDATE_STATUS=37 run_setup > "$tmp/console" || status=$?
[[ "$status" = 37 ]]
cmp "$tmp/console" "$log"
grep -Fq 'Update: CODE_VERSION=fixture' "$log"
if grep -Fq 'Setup:' "$log"; then exit 1; fi
