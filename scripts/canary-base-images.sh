#!/bin/bash
# File one "canary" issue for each newer stable base-image series.
#
# Compares the Debian, Alpine, and Fedora pins in versions.env with the stable
# tags in Docker Official Images. A maintainer makes each bump in a reviewed
# PR, because these images become defaults that jailbox ships. Each issue is
# filed once per series; closing it without bumping skips that series.
#
# Requires: curl, gh with GH_TOKEN (issues: write).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=versions.env
source "$ROOT/versions.env"
# shellcheck source=scripts/lib/base-images.sh
source "$ROOT/scripts/lib/base-images.sh"

stable_image_version() {
    local image=$1 pattern=$2
    # Fedora publishes a numbered Rawhide tag. Read only the tag list that
    # also contains latest, and preserve the precision of our numeric pins.
    curl -fsSL --retry 3 --retry-all-errors --retry-max-time 45 --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/docker-library/official-images/master/library/$image" |
        awk -v pattern="$pattern" '
            /^Tags: / {
                count = split(substr($0, 7), tags, /, */)
                for (i = 1; i <= count; i++) {
                    if (tags[i] != "latest") continue
                    for (j = 1; j <= count; j++) {
                        if (tags[j] !~ pattern) continue
                        candidate = tags[j]
                        matches++
                    }
                }
            }
            END {
                if (matches != 1) exit 1
                print candidate
            }
        '
}

report_image() {
    local image=$1 key="BASE_IMAGE_${1^^}" current pattern version newest title titles role
    current=${!key-}
    pattern=$(base_image_pattern "$image") || return 1
    if [[ "$current" != "$image:"* || ! "${current#*:}" =~ $pattern ]]; then
        printf 'Error: %s must name a numbered %s release\n' "$key" "$image" >&2
        return 1
    fi
    if ! version=$(stable_image_version "$image" "$pattern"); then
        printf 'Error: could not identify the numbered stable %s image\n' "$image" >&2
        return 1
    fi
    newest=$(printf '%s\n' "${current#*:}" "$version" | sort -V | tail -n 1) || return 1
    if [[ "$newest" == "${current#*:}" ]]; then
        printf '%s: pinned %s is current\n' "$image" "$current" >&2
        return 0
    fi

    title="Canary: newer stable base image $image:$version"
    # Match open and closed issues, so a closed issue skips this series.
    titles=$(gh issue list --label canary --state all --limit 1000 --json title --jq '.[].title') || return 1
    if grep -Fxq -- "$title" <<< "$titles"; then
        printf '%s: %s already has an issue\n' "$image" "$image:$version" >&2
        return 0
    fi
    case "$image" in
        alpine) role='Alpine is the base of the egress proxy image that jailbox builds, so mention the new proxy base in the release notes.' ;;
        debian) role='Debian is the base of the Containerfile that jailbox init writes, so mention the new default in the release notes.' ;;
        *) role="${image^} is used only for test coverage; no release note is needed." ;;
    esac
    gh issue create --label canary --title "$title" --body "Docker Official Images marks $image:$version as the stable $image series. versions.env pins $current.

To update, run \`bash scripts/bump-base-image.sh $image:$version\`, commit the result, and open a PR; the PR gates test the new image. $role

Close this issue without a bump to skip this series."
}

gh label create canary --description "Filed by the canary workflow" --force >/dev/null 2>&1 || true
failed=0
for image in "${BASE_IMAGES[@]}"; do
    report_image "$image" || failed=1
done
exit "$failed"
