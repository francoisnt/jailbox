#!/bin/bash
set -euo pipefail
source "$1/tests/lib/lifecycle-jobs.sh"
run="$2"
record_job() {
    local IFS='|'
    cat >/dev/null # Must not consume another catalog record.
    if [[ ${POOL_TEST_BARRIER:-false} = true ]]; then
        touch "$run/barrier-$BASHPID"
        local deadline=$((SECONDS + 5))
        while [[ $(find "$run" -name 'barrier-*' | wc -l) -lt 2 ]]; do
            [[ "$SECONDS" -lt "$deadline" ]] || exit 1
            sleep 0.01
        done
    fi
    if [[ "$1" = fail ]]; then false; fi
    printf '%s\n' "$*" >> "$run/visited-$BASHPID"
}
lifecycle_run_queue "$run" record_job
