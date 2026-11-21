#!/bin/bash
# shellcheck source=tests/lib/lifecycle-contracts.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lifecycle-contracts.sh"

lifecycle_require_fault_coverage() {
    local trace="$1" command="$2" policy="$3" requirements requirement minimum pattern count
    requirements=$(lifecycle_fault_requirements "$command" "$policy") || return 1
    while IFS='|' read -r requirement minimum pattern; do
        count=$(LC_ALL=C grep -Ec -- "$pattern" "$trace") || {
            [[ "$count" = 0 ]] || return 1
        }
        if ((count < minimum)); then
            printf 'Missing fault coverage [%s:%s]: %s (need %s, recorded %s)\n' \
                "$command" "$policy" "$requirement" "$minimum" "$count" >&2
            return 1
        fi
    done <<< "$requirements"
}

# Normalize only allocation suffixes, retaining the operation and its operands.
# Staging file and directory names vary between otherwise identical fixtures,
# and forwarding start receives the newly created container's random ID.
lifecycle_event_identity() {
    sed -E 's/(\.ssh-generation\.|gitconfig\.tmp\.|\.home-setup-complete\.)[[:alnum:]]+/\1ALLOCATED/g
        s/^(jailbox-core [^ ]+ start [^ ]+ )[0-9a-f]{64}( |$)/\1CONTAINER\2/'
}

# Also blank what legitimately differs between workers: the fixture directory,
# project and configuration hashes, the per-project subnet, and the SSH port.
# Everything else must match for two workers to have performed the same operations.
lifecycle_worker_neutral_event() {
    lifecycle_event_identity |
        sed -E 's#/tmp/jailbox-e2e-lifecycle\.[[:alnum:]]+#FIXTURE#g; s/[0-9a-f]{12,}/HASH/g
            s/10\.240\.[0-9]+\./10.240.SUBNET./g; s/127\.0\.0\.1:[0-9]+:/127.0.0.1:PORT:/g'
}

lifecycle_same_fault_event() {
    local expected actual point="$3"
    [[ "$point" =~ ^[1-9][0-9]*$ ]] || return 1
    expected=$(sed -n "${point}p" "$1" | lifecycle_event_identity) || return 1
    actual=$(sed -n "${point}p" "$2" | lifecycle_event_identity) || return 1
    [[ -n "$expected" && "$expected" = "$actual" ]]
}

# Identity and state must occur in the same diagnostic record. Token boundaries
# prevent a proxy name or 'not-running' from satisfying the development record.
lifecycle_reports_state() {
    LC_ALL=C awk -v name="$2" -v state="$3" -f "${BASH_SOURCE[0]%/*}/lifecycle/reports-state.awk" "$1"
}
