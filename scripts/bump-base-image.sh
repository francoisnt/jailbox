#!/bin/bash
# Update one base-image pin in versions.env and regenerate the files built
# from it. Commit the result and open a PR; the PR gates test the new image.
#
# Usage: scripts/bump-base-image.sh IMAGE:VERSION   (for example debian:13)
#
# The pin file and generated files must be tracked, with no staged or
# unstaged changes, so a failure can restore them from Git without touching
# anyone's edits.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=scripts/lib/base-images.sh
source "$ROOT/scripts/lib/base-images.sh"

generate() { bash "$ROOT/scripts/gen-tested-matrix.sh" "$@"; }

ref=${1-}
image=${ref%%:*}
if (($# != 1)) || [[ "$ref" != *:* ]] || ! pattern=$(base_image_pattern "$image") ||
    [[ ! "${ref#*:}" =~ $pattern ]]; then
    printf 'usage: %s IMAGE:VERSION, with a numbered %s release\n' \
        "${0##*/}" "$(IFS=/; echo "${BASE_IMAGES[*]}")" >&2
    exit 2
fi
key="BASE_IMAGE_${image^^}"

outputs=$(generate --outputs) || exit 1
mapfile -t files <<< "versions.env"$'\n'"$outputs"
if ! git -C "$ROOT" ls-files --error-unmatch -- "${files[@]}" > /dev/null; then
    printf 'Error: %s must all be tracked by Git.\n' "${files[*]}" >&2
    exit 1
fi
# Check the index and the worktree separately: a staged edit can hide behind
# a worktree copy that matches HEAD.
if ! git -C "$ROOT" diff --quiet --cached -- "${files[@]}" || ! git -C "$ROOT" diff --quiet -- "${files[@]}"; then
    printf 'Error: commit or stash your staged or unstaged changes to %s first.\n' "${files[*]}" >&2
    exit 1
fi

# Keep any trailing comment after the quoted value.
if ! updated=$(awk -v key="$key" -v value="$ref" '
    index($0, key "=") == 1 {
        rest = substr($0, length(key) + 2)
        sub(/^"[^"]*"/, "", rest)
        print key "=\"" value "\"" rest
        matches++
        next
    }
    { print }
    END { if (matches != 1) exit 1 }
' "$ROOT/versions.env"); then
    printf 'Error: could not find one %s line in versions.env\n' "$key" >&2
    exit 1
fi
if ! printf '%s\n' "$updated" > "$ROOT/versions.env" || ! generate --write || ! generate --check; then
    # Restore only the worktree, from the index checked above.
    if git -C "$ROOT" checkout -- "${files[@]}"; then
        printf 'Error: could not update %s; the changes were undone.\n' "$key" >&2
    else
        printf 'Error: could not update %s, and undoing it failed; restore %s from Git.\n' "$key" "${files[*]}" >&2
    fi
    exit 1
fi
printf 'Set %s="%s" and regenerated the derived files.\n' "$key" "$ref"
