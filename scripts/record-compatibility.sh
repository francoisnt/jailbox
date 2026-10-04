#!/bin/bash
# Called only after an existing full gate succeeds. Append to current master
# without touching the tested checkout, runtime pins, or other changes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:?usage: record-compatibility.sh master|vX.Y.Z}"
[[ "$target" == master || "$target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid compatibility target '$target'; expected master or vX.Y.Z." >&2
    exit 2
}
tested_commit=$(git -C "$ROOT" rev-parse HEAD) || exit 1
[[ "$tested_commit" == "${GITHUB_SHA:?}" ]] || {
    echo 'Checkout does not match the tested commit.' >&2
    exit 1
}
history=compatibility/releases.csv
[[ "$target" != master ]] || history=compatibility/master.csv

# Read versions from the revision that was tested, with the existing canary's
# editor overrides. Host versions come directly from its successful runtime job.
# shellcheck source=versions.env
source "$ROOT/versions.env"
export CODE_VERSION="${JAILBOX_CODE_VERSION:-$CODE_VERSION}"
export CODIUM_VERSION="${JAILBOX_CODIUM_VERSION:-$CODIUM_VERSION}"
export CODIUM_COMMIT="${JAILBOX_CODIUM_COMMIT:-$CODIUM_COMMIT}"
export REMOTE_SSH_VERSION="${JAILBOX_REMOTE_SSH_VERSION:-$REMOTE_SSH_VERSION}"
export OPEN_REMOTE_SSH_VERSION="${JAILBOX_OPEN_REMOTE_SSH_VERSION:-$OPEN_REMOTE_SSH_VERSION}"
export BASE_IMAGE_DEBIAN BASE_IMAGE_ALPINE BASE_IMAGE_FEDORA

work="$(mktemp -d)"
# shellcheck disable=SC2329 # Called by EXIT trap.
cleanup() {
    git -C "$ROOT" worktree remove --force "$work/checkout" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
for attempt in 1 2 3; do
    git -C "$ROOT" fetch origin master
    base=$(git -C "$ROOT" rev-parse origin/master) || exit 1
    git -C "$ROOT" worktree add --detach "$work/checkout" "$base"
    (cd "$work/checkout" && python3 "$ROOT/scripts/lib/record-compatibility.py" "$target" "$history")
    git -C "$work/checkout" add -- "$history"
    if git -C "$work/checkout" diff --cached --quiet; then exit 0; fi
    git -C "$work/checkout" -c user.name=jailbox-ci -c user.email=ci@users.noreply.github.com \
        commit -m "Record tested compatibility for $target"
    if git -C "$work/checkout" push origin HEAD:refs/heads/master; then exit 0; fi
    git -C "$ROOT" fetch origin master || {
        echo 'Push failed and master could not be checked; see Git diagnostics above.' >&2
        exit 1
    }
    current=$(git -C "$ROOT" rev-parse origin/master) || exit 1
    if [[ "$current" == "$base" ]]; then
        echo 'Push failed while master was unchanged; see Git diagnostics above. Not retrying.' >&2
        exit 1
    fi
    git -C "$ROOT" worktree remove --force "$work/checkout"
    if (( attempt < 3 )); then
        echo "Push failed and master changed; retrying the history append ($attempt/3)." >&2
    fi
done
echo 'Could not append compatibility; rerun this reporting job.' >&2
exit 1
