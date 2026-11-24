#!/bin/bash
# Append test results to the compatibility history on the data-only branch
# named in scripts/lib/compatibility-history.sh, without touching the tested
# checkout, its pins, or master.
#
# Usage: scripts/record-compatibility.sh vX.Y.Z
#          Record a published release's own row. Reads the pins of this
#          checkout, which must be TESTED_COMMIT, and TESTED_AT, TEST_RUN_URL,
#          RUNTIME_BASH_VERSION, and RUNTIME_PODMAN_VERSION.
#        scripts/record-compatibility.sh --editor-check FILE
#          Record the editor-check row produced by report-release-check.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="$ROOT/scripts/lib/compatibility_history.py"
usage() { echo 'usage: record-compatibility.sh vX.Y.Z | --editor-check FILE' >&2; exit 2; }
# shellcheck source=scripts/lib/compatibility-history.sh
source "$ROOT/scripts/lib/compatibility-history.sh"
branch=$COMPATIBILITY_BRANCH
history=$COMPATIBILITY_HISTORY

work="$(mktemp -d)"
# shellcheck disable=SC2329 # Called by EXIT trap.
cleanup() {
    git -C "$ROOT" worktree remove --force "$work/checkout" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

if [[ "${1-}" == --editor-check && $# -eq 2 ]]; then
    jq -e 'select(.kind == "editor-check")' "$2" > "$work/row" || exit 1
    target='published release editor check'
elif [[ $# -eq 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    target=$1
    tested_commit=$(git -C "$ROOT" rev-parse HEAD) || exit 1
    [[ "$tested_commit" == "${TESTED_COMMIT:?}" ]] || {
        echo 'Checkout does not match the tested commit.' >&2
        exit 1
    }
    python3 "$RULES" release-row "$target" "$tested_commit" "$ROOT/versions.env" > "$work/row" || exit 1
else
    case "${1-}" in
        --editor-check) usage ;;
        "") usage ;;
        *) echo "Invalid compatibility target '$1'; expected vX.Y.Z or --editor-check FILE." >&2; exit 2 ;;
    esac
fi

for attempt in 1 2 3; do
    fetch_compatibility_history "$ROOT" || exit 1
    base=$(git -C "$ROOT" rev-parse --verify "$COMPATIBILITY_REF^{commit}") || exit 1
    git -C "$ROOT" worktree add --detach "$work/checkout" "$base"
    python3 "$RULES" append "$work/checkout/$history" < "$work/row"
    git -C "$work/checkout" add -- "$history"
    if git -C "$work/checkout" diff --cached --quiet; then exit 0; fi
    git -C "$work/checkout" \
        -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -m "Record tested compatibility for $target"
    # Land only on the history this append started from.
    if git -C "$work/checkout" push --force-with-lease="refs/heads/$branch:$base" \
        origin "HEAD:refs/heads/$branch"; then
        exit 0
    fi
    fetch_compatibility_history "$ROOT" || {
        echo "Push failed and the $branch branch could not be checked; see Git diagnostics above." >&2
        exit 1
    }
    current=$(git -C "$ROOT" rev-parse --verify "$COMPATIBILITY_REF^{commit}") || exit 1
    if [[ "$current" == "$base" ]]; then
        echo "Push failed while the $branch branch was unchanged; see Git diagnostics above. Not retrying." >&2
        exit 1
    fi
    git -C "$ROOT" worktree remove --force "$work/checkout"
    if (( attempt < 3 )); then
        echo "Push failed and the $branch branch changed; retrying the history append ($attempt/3)." >&2
    fi
done
echo 'Could not append compatibility; rerun this reporting job.' >&2
exit 1
