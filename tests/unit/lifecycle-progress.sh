#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/worker-1" "$tmp/worker-2"
lifecycle_fixed_cases > "$tmp/expected-fixed"
: > "$tmp/worker-1/cases"
: > "$tmp/worker-2/cases"
: > "$tmp/worker-1/expected-faults"
: > "$tmp/worker-2/expected-faults"
[[ $(lifecycle_case_label "$tmp" absent.up) = 'CASE [matrix 1/144] absent.up' ]] || fail 'matrix numbering'
[[ $(lifecycle_case_label "$tmp" trace.up.false) = 'CASE [discovery 1/7] trace.up.false' ]] || fail 'discovery numbering'
[[ $(lifecycle_case_label "$tmp" failed-new-container-cleanup) = 'CASE [targeted failures 1/13] failed-new-container-cleanup' ]] || fail 'targeted numbering'
lifecycle_progress "$tmp" | grep -Fq '0/164 known completed' || fail 'initial provisional total'
printf '%s\n' 'interrupt.up.false.1.before' 'interrupt.up.false.1.barrier' > "$tmp/worker-2/expected-faults"
[[ $(lifecycle_case_label "$tmp" interrupt.up.false.1.barrier) = 'CASE [interruptions up/false 2/2] interrupt.up.false.1.barrier' ]] || fail 'trace-local numbering'
printf '%s\n' 'absent.up|2' 'interrupt.up.false.1.before|3' > "$tmp/worker-2/cases"
lifecycle_progress "$tmp" | grep -Fq '2/166 known completed | matrix 1/144 | discovery 0/7 | interruptions 1/2 known (discovering) | targeted 0/13' || fail 'cross-worker progress'
awk '/^trace\./ {print $0 "|1"}' "$tmp/expected-fixed" > "$tmp/worker-1/cases"
lifecycle_progress "$tmp" | grep -Fq '9/166 completed | matrix 1/144 | discovery 7/7 | interruptions 1/2 | targeted 0/13' || fail 'final discovered total'
if lifecycle_case_label "$tmp" nonexistent >/dev/null; then fail 'unknown case accepted'; fi
pass 'numbered case types and dynamic completion totals across workers'

# Exercise the real gate dispatcher with stand-ins for expensive suites.
mkdir -p "$tmp/tree/tests/lib" "$tmp/tree/tests/integration" "$tmp/tree/tests/e2e" "$tmp/bin"
cp "$ROOT/tests/run" "$tmp/tree/tests/run"
cp "$ROOT/tests/lib/logging.sh" "$tmp/tree/tests/lib/"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/podman"
chmod +x "$tmp/bin/podman"
cp "$tmp/bin/podman" "$tmp/bin/setsid"
for suite in integration/wrapper-images integration/lifecycle-state e2e/headless; do
    # shellcheck disable=SC2016 # Generated fixture expands its own environment.
    printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$SUITE_TRACE"\n' "$suite" > "$tmp/tree/tests/$suite.sh"
done
export SUITE_TRACE="$tmp/suites"
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime > "$tmp/output"
[[ $(wc -l < "$SUITE_TRACE") -eq 2 ]] || fail 'default runtime suite count'
if grep -q lifecycle "$SUITE_TRACE"; then fail 'matrix ran without opt-in'; fi
: > "$SUITE_TRACE"
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime-full > "$tmp/output"
[[ $(wc -l < "$SUITE_TRACE") -eq 3 ]] || fail 'full runtime suite count'
grep -Fxq integration/lifecycle-state "$SUITE_TRACE" || fail 'matrix missing with opt-in'
: > "$SUITE_TRACE"
if PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime-typo > "$tmp/output" 2>&1; then fail 'invalid runtime variant accepted'; fi
[[ ! -s "$SUITE_TRACE" ]] || fail 'suite ran before option validation'
pass 'runtime-full retains standard suites and rejects invalid variants'
