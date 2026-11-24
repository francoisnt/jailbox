#!/bin/bash
# Where the compatibility history lives. Automation never commits to master,
# so test results go to their own data-only branch. Sourced by
# scripts/record-compatibility.sh and scripts/plan-release-check.sh.

# shellcheck disable=SC2034 # Read by the sourcing scripts.
COMPATIBILITY_BRANCH=compatibility
# shellcheck disable=SC2034 # Read by the sourcing scripts.
COMPATIBILITY_HISTORY=releases.csv
# shellcheck disable=SC2034 # Read by the sourcing scripts.
COMPATIBILITY_REF=refs/remotes/origin/$COMPATIBILITY_BRANCH

# Update COMPATIBILITY_REF in the repository at $1 from origin.
fetch_compatibility_history() {
    git -C "$1" fetch --quiet origin "+refs/heads/$COMPATIBILITY_BRANCH:$COMPATIBILITY_REF" || {
        printf 'Error: could not fetch the %s branch, which holds the compatibility history.\n' \
            "$COMPATIBILITY_BRANCH" >&2
        return 1
    }
}
