#!/bin/bash
# Report the canary outcome: file/close tracking issues and auto-advance pins.
#
# Runs in the canary workflow's report job. Requires the gh CLI with GH_TOKEN
# (permissions: contents: write, issues: write) and a checkout of the SHA the
# suite tested.
#
# Usage: scripts/canary-report.sh <success|failure>
# Env:   NEW_CODIUM_VERSION NEW_CODE_VERSION NEW_REMOTE_SSH_VERSION
#        NEW_OPEN_REMOTE_SSH_VERSION   version set the suite tested
#        NEW_CODIUM_COMMIT             VSCodium build commit (success only)
#        TESTED_SHA                    jailbox commit the suite ran against
#
# failure: file one issue per version set (deduped by exact title, labeled
#          "canary"); a rerun that goes green bumps normally.
# success: write the new pins + PINS_LAST_VERIFIED into versions.env,
#          regenerate the README matrix, and push directly to master — but
#          only if origin/master still equals TESTED_SHA. The push uses
#          --force-with-lease pinned to TESTED_SHA as an atomic
#          compare-and-swap, so a race skips instead of clobbering; the next
#          canary run retests on top of the moved master. Then close any open
#          canary issue for this version set.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

result="${1:?usage: canary-report.sh <success|failure>}"

: "${NEW_CODIUM_VERSION:?}" "${NEW_CODE_VERSION:?}" "${NEW_REMOTE_SSH_VERSION:?}" \
  "${NEW_OPEN_REMOTE_SSH_VERSION:?}" "${TESTED_SHA:?}"

version_set="codium ${NEW_CODIUM_VERSION}, code ${NEW_CODE_VERSION}, remote-ssh ${NEW_REMOTE_SSH_VERSION}, open-remote-ssh ${NEW_OPEN_REMOTE_SSH_VERSION}"
issue_title="Canary: latest upstream versions failed (${version_set})"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

# gh's --jq has no arg binding; match the exact title in shell instead.
open_issue_numbers() {
    gh issue list --label canary --state open --json number,title \
        --jq '.[] | "\(.number)\t\(.title)"' \
        | awk -F'\t' -v t="$issue_title" '$2 == t { print $1 }'
}

file_failure_issue() {
    gh label create canary --description "Filed by the canary workflow" \
        --force >/dev/null 2>&1 || true

    if [[ -n "$(open_issue_numbers)" ]]; then
        echo "Open canary issue already tracks this version set; not filing a duplicate." >&2
        return 0
    fi

    gh issue create --label canary --title "$issue_title" --body "$(cat <<EOF
The canary ran the full gate-equivalent suite at the latest upstream versions and failed.

Version set:
- VSCodium: ${NEW_CODIUM_VERSION}
- VS Code: ${NEW_CODE_VERSION}
- ms-vscode-remote.remote-ssh: ${NEW_REMOTE_SSH_VERSION}
- jeanp413.open-remote-ssh: ${NEW_OPEN_REMOTE_SSH_VERSION}

Tested jailbox commit: ${TESTED_SHA}
Failing run: ${run_url}

The release gate keeps using the pinned versions in versions.env, so releases are not blocked. Alpine/VSCodium is a best-effort tier: the pinned combination is release-blocking, latest-version failures are tracked here. Pins will not advance until a canary run at this (or a newer) version set goes green.
EOF
)"
}

close_tracking_issues() {
    local n
    for n in $(open_issue_numbers); do
        gh issue close "$n" --comment \
            "Canary went green at this version set (${run_url}); pins advanced."
    done
}

bump_pins() {
    : "${NEW_CODIUM_COMMIT:?NEW_CODIUM_COMMIT is required on success}"
    local today
    today="$(date -u +%F)"

    if [[ "$(git -C "$JAILBOX_DIR" rev-parse HEAD)" != "$TESTED_SHA" ]]; then
        echo "Checkout ($(git -C "$JAILBOX_DIR" rev-parse HEAD)) is not the tested SHA ($TESTED_SHA); refusing to bump." >&2
        return 1
    fi

    sed -i -E \
        -e "s|^CODIUM_VERSION=\"[^\"]*\"|CODIUM_VERSION=\"${NEW_CODIUM_VERSION}\"|" \
        -e "s|^CODIUM_COMMIT=\"[^\"]*\"|CODIUM_COMMIT=\"${NEW_CODIUM_COMMIT}\"|" \
        -e "s|^CODE_VERSION=\"[^\"]*\"|CODE_VERSION=\"${NEW_CODE_VERSION}\"|" \
        -e "s|^REMOTE_SSH_VERSION=\"[^\"]*\"|REMOTE_SSH_VERSION=\"${NEW_REMOTE_SSH_VERSION}\"|" \
        -e "s|^OPEN_REMOTE_SSH_VERSION=\"[^\"]*\"|OPEN_REMOTE_SSH_VERSION=\"${NEW_OPEN_REMOTE_SSH_VERSION}\"|" \
        -e "s|^PINS_LAST_VERIFIED=\"[^\"]*\"|PINS_LAST_VERIFIED=\"${today}\"|" \
        "$JAILBOX_DIR/versions.env"

    bash "$JAILBOX_DIR/scripts/gen-tested-matrix.sh" --write

    if git -C "$JAILBOX_DIR" diff --quiet; then
        echo "Pins already current; nothing to bump." >&2
        return 0
    fi

    git -C "$JAILBOX_DIR" add versions.env README.md
    git -C "$JAILBOX_DIR" \
        -c user.name="jailbox-canary" \
        -c user.email="canary@users.noreply.github.com" \
        commit -m "Advance version pins after green canary

Verified by ${run_url} against ${TESTED_SHA}.

${version_set}"

    # Atomic fast-forward guard: only lands if master is still the tested SHA.
    if git -C "$JAILBOX_DIR" push \
        --force-with-lease="refs/heads/master:${TESTED_SHA}" \
        origin HEAD:refs/heads/master; then
        echo "Pins advanced on master." >&2
        close_tracking_issues
    else
        echo "master moved past the tested SHA; skipping the bump (next canary run retests)." >&2
    fi
}

case "$result" in
    success) bump_pins ;;
    failure) file_failure_issue ;;
    *) echo "unknown result: $result (want success|failure)" >&2; exit 2 ;;
esac
