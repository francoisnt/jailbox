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
