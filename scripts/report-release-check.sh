#!/bin/bash
# Record the daily editor check and file an issue for a confirmed failure.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULES="$ROOT/scripts/lib/compatibility_history.py"
# shellcheck source=scripts/lib/compatibility-history.sh
source "$ROOT/scripts/lib/compatibility-history.sh"
tag=${RELEASE_TAG:?}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

git -C "$ROOT" fetch --quiet origin "refs/tags/$tag:refs/tags/$tag"
commit=$(git -C "$ROOT" rev-parse "$tag^{commit}")
git -C "$ROOT" show "$commit:versions.env" > "$work/pins"
python3 "$RULES" check-row "$tag" "$commit" "$work/pins" > "$work/row"
result=$(jq -re .result "$work/row")
printf 'Published release check for %s: %s\n' "$tag" "$result"

# A rerun of this report finds its result already recorded; it then files no
# second issue. A rerun after a failed recording may still file a duplicate.
fetch_compatibility_history "$ROOT" || exit 1
git -C "$ROOT" show "$COMPATIBILITY_REF:$COMPATIBILITY_HISTORY" > "$work/history.csv" || exit 1
seen=$(python3 "$RULES" recorded "$work/history.csv" "$work/row") || exit 1
if [[ "$seen" == true ]]; then
    echo 'This result is already recorded.'
elif [[ "$result" == fail ]]; then
    if [[ "$RELEASE_GO_VERSION" == unsupported ]]; then
        title="Release $tag uses an unsupported Go series"
        description="Go has stopped supporting the series used by $tag. A new jailbox release is needed."
    else
        title="Release $tag fails with new editors"
        description="The editor tests for $tag failed twice with \`$RELEASE_EDITORS\`."
    fi
    body="$description"$'\n\n'"Run: $RUN_URL"$'\n\n'"To retry, delete the matching editor-check row for $tag in releases.csv on the compatibility branch."
    gh label create release-check --description 'Filed by the published release editor check' --force >/dev/null 2>&1 || true
    gh issue create --label release-check --title "$title" --body "$body"
fi
if [[ "$seen" != true ]]; then
    bash "$ROOT/scripts/record-compatibility.sh" --editor-check "$work/row"
fi
[[ "$result" == pass ]]
