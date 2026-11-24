#!/bin/bash
# Plan the daily editor check of the newest published release.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPDATES="$ROOT/scripts/lib/dependency_updates.py"
HISTORY="$ROOT/scripts/lib/compatibility_history.py"
# shellcheck source=scripts/lib/compatibility-history.sh
source "$ROOT/scripts/lib/compatibility-history.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
history="$work/history.csv"
fetch_compatibility_history "$ROOT" || exit 1
git -C "$ROOT" show "$COMPATIBILITY_REF:$COMPATIBILITY_HISTORY" > "$history" || exit 1

tag=$(python3 "$HISTORY" release-target "$history") || exit 1
[[ -n "$tag" ]] || exit 0
git -C "$ROOT" rev-parse --verify "$tag^{commit}" >/dev/null || exit 1
# Older releases lack the stable entry point for installing the test editors.
if ! git -C "$ROOT" cat-file -e "$tag:tests/ci/editor-gate.sh" 2>/dev/null; then
    echo "$tag predates tests/ci/editor-gate.sh; skipping the editor check." >&2
    exit 0
fi

# Build with the newest patch of the tag's own Go series. go-version.sh exits
# 3 once go.dev no longer supports it.
git -C "$ROOT" show "$tag:src/go.mod" > "$work/go.mod" || exit 1
status=0
go_version=$(bash "$ROOT/scripts/go-version.sh" --go-mod "$work/go.mod") || status=$?
case $status in
    0) ;;
    3)
        printf 'release_tag=%s\nrelease_go_version=unsupported\n' "$tag"
        exit 0
        ;;
    *) exit 1 ;;
esac

bash "$ROOT/scripts/resolve-updates.sh" --editors > "$work/editors" || exit 1
editors=$(python3 "$HISTORY" release-editors "$history" "$tag" "$work/editors") || exit 1
[[ -n "$editors" ]] || exit 0

# Reuse the recorded build commit if the latest version already matches the
# checkout. A failed download leaves the check retryable.
codium=$(sed -n 's/^CODIUM_VERSION=//p' "$work/editors") || exit 1
pin=$(python3 "$UPDATES" codium-pin "$ROOT/versions.env") || exit 1
read -r pinned_version pinned_commit <<< "$pin"
complete=false
if [[ "$codium" == "$pinned_version" ]]; then
    commit=$pinned_commit
else
    commit=$(bash "$ROOT/scripts/resolve-codium-commit.sh" "$codium") || commit=''
fi
if [[ -n "$commit" ]]; then
    editors=$(python3 "$UPDATES" complete --update "$editors" --codium-commit "$commit") || exit 1
    complete=true
fi
printf 'release_tag=%s\nrelease_go_version=%s\n' "$tag" "$go_version"
printf 'release_editors=%s\nrelease_editors_complete=%s\n' "$editors" "$complete"
