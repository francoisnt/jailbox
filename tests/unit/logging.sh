#!/bin/bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
TEST_CASE=setup
trap 'printf "FAIL [%s] line %s\n" "$TEST_CASE" "$LINENO" >&2' ERR
pass() { printf 'PASS: %s\n' "$TEST_CASE"; }

TEST_CASE='timestamping preserves whitespace, backslashes and final partial lines'
printf '  one\\two\n\nlast' > "$FIXTURE/input"
TZ=Pacific/Honolulu test_timestamp_stream < "$FIXTURE/input" > "$FIXTURE/output"
[[ $(wc -l < "$FIXTURE/output") = 3 ]]
grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] ' "$FIXTURE/output"
sed 's/^\[[^]]*\] //' "$FIXTURE/output" > "$FIXTURE/actual"
{ cat "$FIXTURE/input"; printf '\n'; } > "$FIXTURE/expected"
cmp "$FIXTURE/expected" "$FIXTURE/actual"
pass

TEST_CASE='replayed logs retain the original timestamp'
printf '[2000-01-02T03:04:05Z] old output\n      [2000-01-02T03:04:06Z] indented output\n' > "$FIXTURE/input"
test_timestamp_stream < "$FIXTURE/input" > "$FIXTURE/output"
cmp "$FIXTURE/input" "$FIXTURE/output"
pass

TEST_CASE='capture joins output and preserves failure status and caller state'
changed=no
emit_failure() {
    changed=yes
    printf 'stdout\n'
    printf 'stderr\n' >&2
    return 37
}
result=0
test_log_capture "$FIXTURE/capture" emit_failure || result=$?
[[ "$result" = 37 && "$changed" = yes ]]
[[ $(wc -l < "$FIXTURE/capture") = 2 ]]
grep -q '] stdout$' "$FIXTURE/capture"
grep -q '] stderr$' "$FIXTURE/capture"
pass

TEST_CASE='entrypoint preserves stdin, errexit and exit traps'
cat > "$FIXTURE/entrypoint" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
source "$1/tests/lib/logging.sh"
test_log_entrypoint "$0" "$@"
trap 'echo cleanup >&2' EXIT
cat
false
echo unreachable
SCRIPT
result=0
printf 'caller input\n' | bash "$FIXTURE/entrypoint" "$ROOT" > "$FIXTURE/output" || result=$?
[[ "$result" = 1 ]]
grep -q '] caller input$' "$FIXTURE/output"
grep -q '] cleanup$' "$FIXTURE/output"
[[ $(wc -l < "$FIXTURE/output") = 2 ]]
pass
