#!/bin/bash
# The daily editor check of the newest published release: planning it and
# recording its result on the compatibility branch. Each scenario builds its
# own repository with a published v1.0.0 and a local stand-in for GitHub.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=tests/lib/dependency-updates-fixture.sh
source "$ROOT/tests/lib/dependency-updates-fixture.sh"

HISTORY_HEADER=$(cd "$ROOT/scripts/lib" && python3 -c 'import compatibility_history as h; print(",".join(h.RELEASE_FIELDS))')
# The newest editors, with VSCodium's build commit from its package.
EDITORS="CODE_VERSION=1.1.0 REMOTE_SSH_VERSION=0.1.0 OPEN_REMOTE_SSH_VERSION=0.2.0 CODIUM_VERSION=1.0.2 CODIUM_COMMIT=$CODIUM_BUILD_COMMIT"

# Create DIR with v1.0.0 published on DIR.git, which has a compatibility
# branch holding v1.0.0's release row unless HISTORY is false. The tag
# carries the editor gate script unless GATE is false.
make_release_repo() {
    local dir=$1 gate=${2:-true} history=${3:-true}
    make_repo "$dir"
    if [[ $gate == true ]]; then
        cp "$ROOT/tests/ci/editor-gate.sh" "$dir/tests/ci/"
        git -C "$dir" add tests/ci/editor-gate.sh
        git_as -C "$dir" commit -qm 'Add editor gate'
    fi
    git_as -C "$dir" tag v1.0.0
    git init -q --bare -b master "$dir.git"
    git -C "$dir" remote add origin "$dir.git"
    git -C "$dir" push -q origin master v1.0.0
    [[ $history == true ]] || return 0
    git init -q -b compatibility "$dir.history"
    {
        printf '%s\n' "$HISTORY_HEADER"
        printf 'v1.0.0,release,%s,2026-01-01T00:00:00Z,pass,1.0.0,1.0.1,%s,0.1.0,0.2.0,debian:12,alpine:3.24,fedora:41,5.2,4.9,https://example.invalid/run\n' \
            "$(git -C "$dir" rev-parse v1.0.0)" "$(printf 'c%.0s' {1..40})"
    } > "$dir.history/releases.csv"
    git -C "$dir.history" add releases.csv
    git_as -C "$dir.history" commit -qm 'history fixture'
    git -C "$dir.history" push -q "$dir.git" compatibility
}
plan() { bash "$repo/scripts/plan-release-check.sh" > "$tmp/plan" 2> "$tmp/log"; }
history_rows() { git --git-dir="$repo.git" show compatibility:releases.csv; }

# Report the check. Callers pass each editor job's output as CODE_OUTCOME and
# CODIUM_OUTCOME; an editor job that left none is omitted.
report() {
    env GH_LOG="$repo.gh" RELEASE_TAG=v1.0.0 RELEASE_GO_VERSION=1.27.9 RELEASE_EDITORS="$EDITORS" \
        RUN_URL=https://example.invalid/run/1 "$@" bash "$repo/scripts/report-release-check.sh" > "$tmp/log" 2>&1
}

test_plan_requires_the_history_branch() {
    repo=$tmp/no-history
    make_release_repo "$repo" true false
    if plan; then fail 'planning passed without the history branch'; fi
    expect_line "$tmp/log" 'Error: could not fetch the compatibility branch, which holds the compatibility history.'
}

test_plan_skips_releases_without_the_editor_gate() {
    repo=$tmp/no-gate
    make_release_repo "$repo" false
    plan || { cat "$tmp/log" >&2; fail 'planning failed'; }
    [[ ! -s "$tmp/plan" ]] || fail 'a release without the editor gate was planned'
    grep -Fq 'predates tests/ci/editor-gate.sh' "$tmp/log"
}

test_plan_targets_the_newest_editors() {
    repo=$tmp/targets
    make_release_repo "$repo"
    plan || { cat "$tmp/log" >&2; fail 'planning failed'; }
    expect_line "$tmp/plan" 'release_tag=v1.0.0'
    expect_line "$tmp/plan" 'release_go_version=1.27.9'
    expect_line "$tmp/plan" "release_editors=$EDITORS"
    expect_line "$tmp/plan" 'release_editors_complete=true'
    # A failed package download leaves the check incomplete and retryable.
    CODIUM_ARCHIVE=/nonexistent plan || { cat "$tmp/log" >&2; fail 'planning failed without the package'; }
    expect_line "$tmp/plan" "release_editors=${EDITORS% CODIUM_COMMIT=*}"
    expect_line "$tmp/plan" 'release_editors_complete=false'
    # When master already pins the newest VSCodium, its build commit is reused.
    local pinned
    pinned=$(printf 'f%.0s' {1..40})
    bash "$repo/scripts/apply-updates.sh" CODIUM_VERSION=1.0.2 "CODIUM_COMMIT=$pinned" > /dev/null
    git_as -C "$repo" commit -qam 'Pin VSCodium 1.0.2'
    CODIUM_ARCHIVE=/nonexistent plan || { cat "$tmp/log" >&2; fail 'planning failed with a current pin'; }
    expect_line "$tmp/plan" "release_editors=${EDITORS% CODIUM_COMMIT=*} CODIUM_COMMIT=$pinned"
    expect_line "$tmp/plan" 'release_editors_complete=true'
}

test_report_records_results_on_the_history_branch() {
    repo=$tmp/report
    make_release_repo "$repo"
    : > "$repo.gh"
    local master before lone
    master=$(git --git-dir="$repo.git" rev-parse master)
    # A failure is recorded only after its issue is filed.
    before=$(git --git-dir="$repo.git" rev-parse compatibility)
    if report CODE_OUTCOME=test-fail CODIUM_OUTCOME=pass GH_FAIL=1; then fail 'issue filing failure passed'; fi
    [[ $(git --git-dir="$repo.git" rev-parse compatibility) == "$before" ]] || fail 'a failure was recorded without its issue'
    # One editor's repeated failure fails the check.
    lone=${EDITORS/CODE_VERSION=1.1.0/CODE_VERSION=1.2.0}
    if report RELEASE_EDITORS="$lone" CODE_OUTCOME=test-fail; then fail 'a lone editor failure passed'; fi
    expect_line "$repo.gh" 'TITLE Release v1.0.0 fails with new editors'
    history_rows | grep -Fq ',fail,1.2.0,1.0.2,' || fail 'a lone editor failure was not recorded'
    # Rerunning that report files no second issue and records nothing new.
    before=$(git --git-dir="$repo.git" rev-parse compatibility)
    if report RELEASE_EDITORS="$lone" CODE_OUTCOME=test-fail; then fail 'a rerun report passed'; fi
    expect_line "$tmp/log" 'This result is already recorded.'
    [[ $(grep -c '^TITLE' "$repo.gh") == 1 ]] || fail 'a rerun report filed a second issue'
    [[ $(git --git-dir="$repo.git" rev-parse compatibility) == "$before" ]] || fail 'a rerun report recorded again'
    # An editor job that stopped before classifying its tests left no outcome,
    # so the check is an error even when the other editor passed.
    for missing in '' 'pass\n'; do
        if report CODE_OUTCOME=pass CODIUM_OUTCOME="$missing"; then fail 'a missing outcome passed'; fi
        history_rows | tail -n 1 | grep -Fq ',error,1.1.0,1.0.2,' || fail 'a missing outcome was not recorded as an error'
    done
    # A pass is recorded, and the same versions are not planned again.
    before=$(git --git-dir="$repo.git" rev-parse compatibility)
    report CODE_OUTCOME=pass CODIUM_OUTCOME=pass || { cat "$tmp/log" >&2; fail 'reporting a passing release check failed'; }
    [[ $(git --git-dir="$repo.git" diff --name-only "$before" compatibility) == releases.csv ]]
    history_rows | tail -n 1 | grep -Fq ',pass,1.1.0,1.0.2,' || fail 'the pass was not recorded'
    plan || { cat "$tmp/log" >&2; fail 'planning failed'; }
    [[ ! -s "$tmp/plan" ]] || fail 'an existing pass did not skip editor testing'
    [[ $(git --git-dir="$repo.git" rev-parse master) == "$master" ]] || fail 'the release check changed master'
}

test_unsupported_go_is_reported_once() {
    repo=$tmp/unsupported
    make_release_repo "$repo"
    : > "$repo.gh"
    printf '[{"version":"go1.29.0","stable":true}]\n' > "$tmp/go-current.json"
    GO_RELEASE_LISTING="$tmp/go-current.json" plan || { cat "$tmp/log" >&2; fail 'planning failed'; }
    expect_line "$tmp/plan" 'release_tag=v1.0.0'
    expect_line "$tmp/plan" 'release_go_version=unsupported'
    if report RELEASE_GO_VERSION=unsupported RELEASE_EDITORS=''; then
        fail 'unsupported Go did not fail the check'
    fi
    expect_line "$repo.gh" 'TITLE Release v1.0.0 uses an unsupported Go series'
    GO_RELEASE_LISTING="$tmp/go-current.json" plan || { cat "$tmp/log" >&2; fail 'planning failed'; }
    [[ ! -s "$tmp/plan" ]] || fail 'an existing Go warning did not skip further checks'
}

test_plan_requires_the_history_branch
test_plan_skips_releases_without_the_editor_gate
test_plan_targets_the_newest_editors
test_report_records_results_on_the_history_branch
test_unsupported_go_is_reported_once
printf 'PASS: published-release editor check\n'
