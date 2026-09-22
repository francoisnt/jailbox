#!/bin/bash
# The matrix observer must enforce byte framing and non-mutation, not merely log
# expected words. Exercise the observer without a container engine.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
LOG="$tmp/log"
mkdir "$LOG"
CASE_KEY=missing-proxy.up
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_die() { fail "$@"; }
snapshot() { printf 'state\n' >> "$tmp/snapshot-calls"; cat "$tmp/state"; }
image_snapshot() { printf 'images\n' >> "$tmp/snapshot-calls"; cat "$tmp/images"; }
cli() {
    [[ "$*" = status ]] || fail 'observer invoked a lifecycle command'
    if [[ -n "$MUTATE" ]]; then printf changed > "$tmp/$MUTATE"; fi
    printf '%s' "$REPLY"
    return "$RESULT"
}
# Connection observation is tested in connection-observer.sh; retain the status oracle.
observe_connection() { :; }
observe_exec() { :; }
observe_shell() { :; }
verify_exec_transport() { :; }
verify_exec_proxy_environment() { :; }
MUTATE=''
RESULT=0
for expected in absent stopped running; do
    REPLY="$expected"$'\n'
    for phase in initial recovered; do
        printf original > "$tmp/state"
        printf original > "$tmp/images"
        matrix_observe "$phase" "$expected" allow
    done
done
[[ $(wc -l < "$LOG/observations") -eq 6 ]] || fail 'missing observations'
[[ $(wc -l < "$tmp/snapshot-calls") -eq 24 ]] || fail 'selected observations omitted snapshots'
[[ -f "$LOG/missing-proxy.up.initial.status.stdout" &&
   -f "$LOG/missing-proxy.up.recovered.status.stdout" ]] || fail 'phase artifacts were overwritten'
successful=6
reject() {
    if (matrix_observe initial absent refuse) > "$tmp/out" 2> "$tmp/err"; then
        fail 'observer accepted invalid output or mutation'
    fi
    [[ -s "$tmp/err" ]] || fail 'missing observer diagnostic'
    [[ $(wc -l < "$LOG/observations") -eq "$successful" ]] || fail 'failed observation recorded success'
}
for REPLY in absent $'absent\n\n' $'running\n' $'progress\nabsent\n' ''; do reject; done
REPLY=$'absent\n'
RESULT=125
reject
RESULT=0
for MUTATE in state images; do reject; done
MUTATE=''

# All selected observations must be reachable through the shared row catalog.
# The original 21 full comparisons cover initial states, support recovery, and both
# cleanup outcomes for every stored home-label class, independent of faults.
# Fifteen health-variant observations bring the bounded total to 36.
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-contracts.sh
source "$ROOT/tests/lib/lifecycle-contracts.sh"
selected=0
check_selection() {
    local command phase
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        case "${LIFECYCLE_COMMAND_CONTRACTS[$command]}" in
            launch) phase=recovered ;;
            stop) phase=stopped ;;
            clean) phase=cleaned ;;
            *) fail 'unhandled lifecycle contract' ;;
        esac
        if status_snapshot_required "$1.$command" initial; then selected=$((selected + 1)); fi
        if status_snapshot_required "$1.$command" "$phase"; then selected=$((selected + 1)); fi
    done
}
lifecycle_each_row check_selection
while IFS= read -r variant; do
    for phase in "health-$variant" "health-$variant-recovered"; do
        [[ "$variant:$phase" != upstream:health-upstream-recovered ]] || continue
        status_snapshot_required running.up "$phase" || fail "missing health snapshot"
        selected=$((selected + 1))
    done
done < <(attachment_health_cases)
[[ "$selected" = 36 ]] || fail 'bounded snapshot cases are missing or unexpectedly expanded'

# Increasing interruption cases preserves every classification assertion and
# produces no extra engine/filesystem snapshots, including recovered phases.
: > "$tmp/snapshot-calls"
for ((i=0; i<100; i++)); do
    CASE_KEY="fault.up.false.after.$i"
    REPLY=$'stopped\n'
    matrix_observe interrupted stopped refuse
    REPLY=$'running\n'
    matrix_observe recovered running allow
done
[[ $(wc -l < "$LOG/observations") -eq 206 ]] || fail 'fault classification was skipped'
[[ ! -s "$tmp/snapshot-calls" ]] || fail 'growing fault coverage added full snapshots'
# Reject failures on the cheap path as well as the full-comparison path.
if (REPLY=$'absent\n'; matrix_observe interrupted stopped refuse) >/dev/null 2>&1; then
    fail 'cheap observation accepted wrong classification'
fi
if (RESULT=125; matrix_observe recovered running allow) >/dev/null 2>&1; then
    fail 'cheap observation accepted failed status'
fi
[[ -f "$LOG/$CASE_KEY.interrupted.status.stdout" &&
   -f "$LOG/$CASE_KEY.recovered.status.stdout" ]] || fail 'fault artifacts lost a phase'

# Required snapshot failures must not count as matching empty snapshots.
CASE_KEY=missing-proxy.up
REPLY=$'absent\n'
successful=206
# shellcheck disable=SC2329 # Called by matrix_observe through reject.
snapshot() { return 42; }
reject
snapshot() { printf stable; }
image_snapshot() { return 42; }
reject
printf 'PASS: all observations enforce framing; bounded cases enforce non-mutation\n'

# Discovered interruptions retain independently expected status and complete
# connection validation, without repeating the exec/shell validation boundary.
CASE_KEY=interrupt.up.false.1.before
REPLY=$'running\n'
observe_connection() { printf 'connection\n' >> "$tmp/checks"; }
observe_exec() { printf 'exec\n' >> "$tmp/checks"; }
observe_shell() { printf 'shell\n' >> "$tmp/checks"; }
: > "$tmp/checks"
matrix_observe interrupted running allow readiness
printf 'connection\n' > "$tmp/expected-checks"
cmp "$tmp/checks" "$tmp/expected-checks"
: > "$tmp/checks"
matrix_observe recovered running allow full
printf 'connection\nexec\nshell\n' > "$tmp/expected-checks"
cmp "$tmp/checks" "$tmp/expected-checks"
grep -Fxq "$CASE_KEY|interrupted|running|allow|readiness" "$LOG/observations"
cp "$LOG/observations" "$tmp/before-refusal"
# shellcheck disable=SC2329 # Invoked inside the observer under test.
observe_connection() { return 42; }
if (matrix_observe interrupted running allow readiness) > "$tmp/out" 2> "$tmp/err"; then
    fail 'readiness failure became success'
fi
cmp "$tmp/before-refusal" "$LOG/observations"
if (matrix_observe interrupted running allow unknown) > "$tmp/out" 2> "$tmp/err"; then
    fail 'unknown observation workload accepted'
fi
cmp "$tmp/before-refusal" "$LOG/observations"
printf 'PASS: readiness workload retains required checks and fails closed\n'

# The shared production probe must retain engine diagnostics in the matrix,
# while ordinary CLI callers keep their existing quiet-probe behavior.
# shellcheck source=src/host/core/resources/inventory.sh
source "$ROOT/src/host/core/resources/inventory.sh"
podman() { printf 'fixture engine inspection failed\n' >&2; return "$ENGINE_RESULT"; }
ENGINE_RESULT=125
if (exists container fixture) > "$tmp/out" 2> "$tmp/err"; then
    fail 'engine error became a known inventory state'
fi
grep -Fq 'fixture engine inspection failed' "$tmp/err"
grep -Fq 'could not inspect container fixture (exit 125)' "$tmp/err"
result=0
jailbox_resource_exists container fixture > "$tmp/out" 2> "$tmp/err" || result=$?
[[ "$result" = 125 && ! -s "$tmp/err" ]] || fail 'quiet production probe changed'
for ENGINE_RESULT in 0 1; do
    result=0
    exists container fixture > "$tmp/out" 2> "$tmp/err" || result=$?
    [[ "$result" = "$ENGINE_RESULT" ]] || fail 'matrix probe changed existence status'
done
printf 'PASS: matrix preserves engine diagnostics and production probe statuses\n'
