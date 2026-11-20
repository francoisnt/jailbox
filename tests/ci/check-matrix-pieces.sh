#!/bin/bash
# Pieces of one interruption sweep may run on different matrix shards. Given
# the downloaded logs of every shard, require each shard's passing run exactly
# once, then check that all pieces of each sweep recorded the same operations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"

die() { printf 'FAIL [matrix pieces]: %s\n' "$*" >&2; exit 1; }
[[ $# = 2 && "$1" =~ ^[1-9][0-9]?$ ]] || die 'usage: tests/ci/check-matrix-pieces.sh SHARD_COUNT LOGS_DIR'
count=$1 logs=$2
[[ -d "$logs" ]] || die "no matrix logs in $logs"
summaries=$(find "$logs" -path '*/matrix/lifecycle/run-summary' -type f -print | LC_ALL=C sort) ||
    die "could not search $logs"
declare -A runs=()
while IFS= read -r summary; do
    [[ -n "$summary" ]] || continue
    shard=$(sed -n 's/^shard=//p' "$summary") || die "could not read $summary"
    [[ "$shard" =~ ^([1-9][0-9]?)/$count$ ]] || die "$summary is not a run of one of $count shards"
    grep -Fxq exit_status=0 "$summary" || die "shard $shard did not pass"
    [[ ! -v runs[$shard] ]] || die "shard $shard has more than one run"
    runs[$shard]=${summary%/run-summary}
done <<< "$summaries"
for ((index = 1; index <= count; index++)); do
    [[ -v runs[$index/$count] ]] || die "shard $index/$count has no run"
done
lifecycle_check_piece_traces "${runs[@]}" || die 'pieces of a split sweep did not match across shards'
printf 'Matrix pieces: every split sweep recorded the same operations across %s shards\n' "$count"
