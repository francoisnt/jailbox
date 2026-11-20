#!/bin/bash
# Shards cannot see each other's work. Given the downloaded logs of every
# shard, require each shard's passing run exactly once and prove together they
# ran the complete matrix: the full job catalog and fixed case list derived
# from this checkout, matching pieces of every split sweep, and focused sweeps
# whose skipped steps run in their covering sweeps. Each shard has already
# checked that it ran every case its own jobs selected.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"

die() { printf 'FAIL [matrix coverage]: %s\n' "$*" >&2; exit 1; }
[[ $# = 2 && "$1" =~ ^[1-9][0-9]?$ ]] || die 'usage: tests/ci/check-matrix-coverage.sh SHARD_COUNT LOGS_DIR'
count=$1 logs=$2
[[ -d "$logs" ]] || die "no matrix logs in $logs"
summaries=$(find "$logs" -path '*/matrix/lifecycle/run-summary' -type f -print | LC_ALL=C sort) ||
    die "could not search $logs"
declare -A runs=()
while IFS= read -r summary; do
    [[ -n "$summary" ]] || continue
    shard=$(sed -n 's/^shard=//p' "$summary") || die "could not read $summary"
    if [[ ! "$shard" =~ ^([1-9][0-9]?)/$count$ ]] || ((BASH_REMATCH[1] > count)); then
        die "$summary is not a run of one of $count shards"
    fi
    grep -Fxq exit_status=0 "$summary" || die "shard $shard did not pass"
    [[ ! -v runs[$shard] ]] || die "shard $shard has more than one run"
    runs[$shard]=${summary%/run-summary}
done <<< "$summaries"
for ((index = 1; index <= count; index++)); do
    [[ -v runs[$index/$count] ]] || die "shard $index/$count has no run"
done

# A job or case missing from every shard passes each shard's own check, so
# compare the shards' union with the full lists rather than with each other.
expected_jobs=$(lifecycle_jobs) || die 'could not list lifecycle jobs'
expected_jobs=$(cut -d '|' -f1 <<< "$expected_jobs" | LC_ALL=C sort)
actual_jobs=$(for run in "${runs[@]}"; do cut -d '|' -f1 "$run/catalog" || exit 1; done) ||
    die 'could not read shard job catalogs'
[[ $(LC_ALL=C sort <<< "$actual_jobs") = "$expected_jobs" ]] ||
    die 'shards together did not run exactly the full job catalog'
expected_cases=$(lifecycle_fixed_cases) || die 'could not list lifecycle cases'
actual_cases=$(cat "${runs[@]/%//expected-fixed}") || die 'could not read shard case lists'
[[ $(LC_ALL=C sort <<< "$actual_cases") = $(LC_ALL=C sort <<< "$expected_cases") ]] ||
    die 'shards together did not run exactly the full fixed case list'

lifecycle_check_piece_traces "${runs[@]}" || die 'pieces of a split sweep did not match across shards'
lifecycle_check_focused_traces "${runs[@]}" || die 'a focused sweep skips steps its covering sweep does not perform'
printf 'Matrix coverage: %s shards ran the full matrix; split and focused sweeps are consistent\n' "$count"
