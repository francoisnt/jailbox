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
[[ $(lifecycle_case_label "$tmp" trace.up.false) = 'CASE [discovery 1/9] trace.up.false' ]] || fail 'discovery numbering'
[[ $(lifecycle_case_label "$tmp" failed-new-container-cleanup) = 'CASE [targeted failures 1/13] failed-new-container-cleanup' ]] || fail 'targeted numbering'
lifecycle_progress "$tmp" | grep -Fq '0/166 known completed' || fail 'initial provisional total'
printf '%s\n' 'interrupt.up.false.1.before' 'interrupt.up.false.1.barrier' > "$tmp/worker-2/expected-faults"
[[ $(lifecycle_case_label "$tmp" interrupt.up.false.1.barrier) = 'CASE [interruptions up/false 2/2] interrupt.up.false.1.barrier' ]] || fail 'trace-local numbering'
printf '%s\n' 'absent.up|2' 'interrupt.up.false.1.before|3' > "$tmp/worker-2/cases"
lifecycle_progress "$tmp" | grep -Fq '2/168 known completed | matrix 1/144 | discovery 0/9 | interruptions 1/2 known (discovering) | targeted 0/13' || fail 'cross-worker progress'
awk '/^trace\./ {print $0 "|1"}' "$tmp/expected-fixed" > "$tmp/worker-1/cases"
lifecycle_progress "$tmp" | grep -Fq '11/168 completed | matrix 1/144 | discovery 9/9 | interruptions 1/2 | targeted 0/13' || fail 'final discovered total'
if lifecycle_case_label "$tmp" nonexistent >/dev/null; then fail 'unknown case accepted'; fi
pass 'numbered case types and dynamic completion totals across workers'

# Exercise the real gate dispatcher with stand-ins for expensive suites.
mkdir -p "$tmp/tree/tests/lib" "$tmp/tree/tests/integration" "$tmp/tree/tests/e2e" "$tmp/bin"
cp "$ROOT/tests/run" "$tmp/tree/tests/run"
cp "$ROOT/tests/lib/logging.sh" "$tmp/tree/tests/lib/"
cp "$ROOT/tests/lib/portable-pool.sh" "$ROOT/tests/lib/run-suite.py" "$tmp/tree/tests/lib/"
mkdir -p "$tmp/tree/scripts/lib"
cp "$ROOT/scripts/lib/"{process-pool,worker-resources}.sh "$tmp/tree/scripts/lib/"
: > "$tmp/tree/tests/lib/portable-parallel.txt"
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/podman"
chmod +x "$tmp/bin/podman"
cp "$tmp/bin/podman" "$tmp/bin/setsid"
# The dispatcher fixture models a Linux host even in the macOS portable gate.
printf '#!/bin/bash\nprintf "Linux\\n"\n' > "$tmp/bin/uname"
chmod 755 "$tmp/bin/uname"
for suite in integration/wrapper-images integration/lifecycle-state e2e/headless; do
    # shellcheck disable=SC2016 # Generated fixture expands its own environment.
    printf '#!/bin/bash\nprintf "%%s|%%s\\n" "%s" "$*" >> "$SUITE_TRACE"\n' "$suite" > "$tmp/tree/tests/$suite.sh"
done
export SUITE_TRACE="$tmp/suites"
for option in --help -h; do
    bash "$tmp/tree/tests/run" "$option" > "$tmp/help"
    grep -Fxq 'Usage: run [dev [SUITE ...]|portable|runtime|matrix|editor]' "$tmp/help" || fail 'help usage missing'
    if grep -q '^\[' "$tmp/help"; then fail 'help contains timestamps'; fi
    [[ ! -s "$SUITE_TRACE" ]] || fail 'help executed a suite'
done
pass 'help prints without timestamps or test execution'
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime > "$tmp/output"
[[ $(wc -l < "$SUITE_TRACE") -eq 2 ]] || fail 'default runtime suite count'
if grep -q lifecycle "$SUITE_TRACE"; then fail 'matrix assertions overlap runtime'; fi
: > "$SUITE_TRACE"
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" matrix > "$tmp/output"
printf 'integration/wrapper-images|--prepare-only debian\nintegration/lifecycle-state|\n' > "$tmp/expected"
cmp "$tmp/expected" "$SUITE_TRACE" || fail 'matrix must prepare only its images and run its own assertions'
: > "$SUITE_TRACE"
if PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime-full > "$tmp/output" 2>&1; then fail 'removed runtime-full alias accepted'; fi
[[ ! -s "$SUITE_TRACE" ]] || fail 'suite ran before option validation'
pass 'runtime and matrix own separate assertions; matrix prepares its own images'
: > "$SUITE_TRACE"
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$tmp/summary" JAILBOX_TEST_LOG_ACTIVE=false JAILBOX_TEST_LOG_SCRIPT='' \
    PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" runtime > "$tmp/ci-output"
grep -Fxq '| runtime | 2 | 0 | 0s |' "$tmp/summary" || \
    grep -Eq '^\| runtime \| 2 \| 0 \| [0-9]+s \|$' "$tmp/summary"
grep -Eq '^\[[0-9:]+\] jailbox tests .* UTC$' "$tmp/ci-output"
pass 'CI gate summary and compact UTC console timestamps'
: > "$SUITE_TRACE"


# The default dispatch includes every gate once, with matrix before editor.
mkdir -p "$tmp/tree/scripts" "$tmp/tree/tests/unit" "$tmp/tree/tests/portable"
for suite in scripts/lint scripts/gen-tested-matrix scripts/gen-public-api tests/portable/smoke tests/e2e/editor-smoke; do
    # shellcheck disable=SC2016 # Generated fixture expands its own environment.
    printf '#!/bin/bash\nprintf "%%s|%%s\\n" "%s" "$*" >> "$SUITE_TRACE"\n' "$suite" > "$tmp/tree/$suite.sh"
done
cp "$tmp/bin/podman" "$tmp/bin/shellcheck"
cp "$tmp/bin/podman" "$tmp/bin/code"
PATH="$tmp/bin:$PATH" DISPLAY=:fixture JAILBOX_EDITOR=code bash "$tmp/tree/tests/run" > "$tmp/output"
cat > "$tmp/expected" <<'EXPECTED'
scripts/lint|
scripts/gen-tested-matrix|--check
scripts/gen-public-api|--check
tests/portable/smoke|
integration/wrapper-images|
e2e/headless|
integration/wrapper-images|--prepare-only debian
integration/lifecycle-state|
integration/wrapper-images|--prepare-only debian fedora
tests/e2e/editor-smoke|
EXPECTED
cmp "$tmp/expected" "$SUITE_TRACE" || fail 'default gate order or suite ownership'
: > "$SUITE_TRACE"
cat > "$tmp/missing-setsid" <<'ENVIRONMENT'
command() {
    if [[ "$*" = '-v setsid' ]]; then return 1; fi
    builtin command "$@"
}
ENVIRONMENT
if PATH="$tmp/bin:$PATH" DISPLAY=:fixture JAILBOX_EDITOR=code BASH_ENV="$tmp/missing-setsid" \
    bash "$tmp/tree/tests/run" > "$tmp/output" 2>&1; then fail 'missing matrix prerequisite accepted'; fi
grep -Fq 'setsid is required for the matrix gate' "$tmp/output" || fail 'missing prerequisite diagnosis'
[[ ! -s "$SUITE_TRACE" ]] || fail 'gate ran before matrix prerequisite validation'
pass 'all four gates run once in order and prerequisites fail before any suite'

# Development selection uses real discovery/pool/supervision in this small tree.
sed 's@tests/portable/smoke@tests/portable/syntax@g' "$tmp/tree/tests/portable/smoke.sh" > "$tmp/tree/tests/portable/syntax.sh"
printf 'slow.sh\n' > "$tmp/tree/tests/lib/dev-exclude.txt"
for suite in fast slow new; do
    # shellcheck disable=SC2016 # The fixture expands its own environment.
    printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$SUITE_TRACE"\n' "$suite" > "$tmp/tree/tests/unit/$suite.sh"
done
: > "$SUITE_TRACE"
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" dev > "$tmp/output"
printf 'tests/portable/syntax|\nscripts/gen-tested-matrix|--check\nscripts/gen-public-api|--check\nfast\nnew\n' > "$tmp/expected"
cmp "$tmp/expected" "$SUITE_TRACE" || fail 'dev defaults, discovery, or phase ownership'
grep -Fq 'Development checks passed — partial coverage' "$tmp/output"
[[ $(grep -Ec 'PASS +dev/' "$tmp/output") = 4 ]] || fail 'wrong dev result labels'
: > "$SUITE_TRACE"
PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" dev slow slow.sh fast > "$tmp/output"
printf 'slow\n' >> "$tmp/expected"
cmp "$tmp/expected" "$SUITE_TRACE" || fail 'explicit additions were omitted or duplicated'
[[ $(grep -Ec 'PASS +dev/' "$tmp/output") = 5 ]] || fail 'wrong explicit-suite result labels'
: > "$SUITE_TRACE"
if bash "$tmp/tree/tests/run" dev missing > "$tmp/output" 2>&1; then fail 'unknown dev suite accepted'; fi
[[ ! -s "$SUITE_TRACE" ]] || fail 'dev started before validating selection'
# A failed selected suite must fail dev and never print a success summary.
printf '#!/bin/bash\nexit 42\n' > "$tmp/tree/tests/unit/slow.sh"
if PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" dev slow > "$tmp/output" 2>&1; then fail 'dev swallowed suite failure'; fi
if grep -q 'Development checks passed' "$tmp/output"; then fail 'dev reported false success'; fi
# Full portable ignores dev exclusions and still discovers every unit suite.
if PATH="$tmp/bin:$PATH" bash "$tmp/tree/tests/run" portable > "$tmp/output" 2>&1; then fail 'portable omitted excluded suite'; fi
grep -Eq 'FAIL +portable/slow' "$tmp/output"
pass 'dev discovery, explicit additions, failure propagation, and full portable membership'
