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

TEST_CASE='detached helpers cannot retain the extra capture writer'
cp "$ROOT/tests/fixtures/logging/detach.sh" "$FIXTURE/detach"
mkfifo "$FIXTURE/notification"
exec {notification}<> "$FIXTURE/notification"
(
    test_log_capture "$FIXTURE/detached-log" bash "$FIXTURE/detach" "$FIXTURE/daemon-pid"
    printf 'complete\n' > "$FIXTURE/notification"
) &
capture_pid=$!
cleanup_capture() {
    kill "$capture_pid" 2>/dev/null || true
    if [[ -f "$FIXTURE/daemon-pid" ]]; then
        kill "$(cat "$FIXTURE/daemon-pid")" 2>/dev/null || true
    fi
    rm -rf "$FIXTURE"
}
trap cleanup_capture EXIT
completed=false
if IFS= read -r -t 5 token <&"$notification"; then
    [[ "$token" != complete ]] || completed=true
fi
# Release a leaked writer even on regression, so the test itself cannot hang.
daemon_pid=$(cat "$FIXTURE/daemon-pid")
kill -0 "$daemon_pid"
kill "$daemon_pid"
wait "$capture_pid"
exec {notification}>&-
trap 'rm -rf "$FIXTURE"' EXIT
[[ "$completed" = true ]]
grep -q '] command finished$' "$FIXTURE/detached-log"
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
cp "$ROOT/tests/fixtures/logging/entrypoint.sh" "$FIXTURE/entrypoint"
result=0
printf 'caller input\n' | bash "$FIXTURE/entrypoint" "$ROOT" > "$FIXTURE/output" || result=$?
[[ "$result" = 1 ]]
grep -q '] caller input$' "$FIXTURE/output"
grep -q '] cleanup$' "$FIXTURE/output"
[[ $(wc -l < "$FIXTURE/output") = 2 ]]
pass

TEST_CASE='terminal progress stays below case output and clears for the summary'
cat > "$FIXTURE/input" <<'LOG'
[2000-01-02T03:04:05Z] Progress: 0/2 completed
[2000-01-02T03:04:06Z] CASE one
[2000-01-02T03:04:07Z] Progress: 1/2 completed
[2000-01-02T03:04:08Z] CASE two
[2000-01-02T03:04:09Z] Progress: 2/2 completed
[2000-01-02T03:04:10Z] Lifecycle: 2/2 cases completed; timings: run/timings
LOG
test_display_stream 80 < "$FIXTURE/input" > "$FIXTURE/output"
{
    printf '\r\033[2KProgress: 0/2 completed'
    printf '\r\033[2K[2000-01-02T03:04:06Z] CASE one\n'
    printf '\r\033[2KProgress: 0/2 completed'
    printf '\r\033[2KProgress: 1/2 completed'
    printf '\r\033[2K[2000-01-02T03:04:08Z] CASE two\n'
    printf '\r\033[2KProgress: 1/2 completed'
    printf '\r\033[2KProgress: 2/2 completed'
    printf '\r\033[2K[2000-01-02T03:04:10Z] Lifecycle: 2/2 cases completed; timings: run/timings\n'
} > "$FIXTURE/expected"
cmp "$FIXTURE/expected" "$FIXTURE/output"
pass

TEST_CASE='redirected logs retain plain progress records'
test_display_stream < "$FIXTURE/input" > "$FIXTURE/output"
cmp "$FIXTURE/input" "$FIXTURE/output"
pass

TEST_CASE='narrow terminal retains every progress count before the next case'
status='Progress: 139/511 completed | matrix 0/144 | discovery 9/9 | interruptions 129/345 | targeted 1/13'
for width in 20 80 "${#status}"; do
    printf '%s\nCASE running\n' "$status" | test_display_stream "$width" > "$FIXTURE/output"
    printf '\r\033[2K%s\nCASE running\n' "$status" > "$FIXTURE/expected"
    cmp "$FIXTURE/expected" "$FIXTURE/output"
done
pass

TEST_CASE='early EOF ends a transient progress line with a newline'
printf 'Progress: 1/2 completed\n' | test_display_stream 80 > "$FIXTURE/output"
[[ $(tail -c 1 "$FIXTURE/output" | od -An -tu1 | tr -d ' ') = 10 ]]
pass

TEST_CASE='lint progress updates in place and clears after every final outcome'
for result in passed failed interrupted; do
    printf 'Progress: ShellCheck: 1/3 batches complete\nproblem in script.sh\nProgress: ShellCheck: 2/3 batches complete\nShellCheck %s · 5s\nnext suite\n' "$result" > "$FIXTURE/input"
    test_display_stream 100 < "$FIXTURE/input" > "$FIXTURE/output"
    {
        printf '\r\033[2KShellCheck: 1/3 batches complete'
        printf '\r\033[2Kproblem in script.sh\n'
        printf '\r\033[2KShellCheck: 1/3 batches complete'
        printf '\r\033[2KShellCheck: 2/3 batches complete'
        printf '\r\033[2KShellCheck %s · 5s\nnext suite\n' "$result"
    } > "$FIXTURE/expected"
    cmp "$FIXTURE/expected" "$FIXTURE/output"
    test_display_stream < "$FIXTURE/input" > "$FIXTURE/output"
    cmp "$FIXTURE/input" "$FIXTURE/output"
done
pass
