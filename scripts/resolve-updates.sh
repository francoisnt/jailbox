#!/bin/bash
# Print the newest version of every pinned dependency as KEY=value lines.
#
# Usage: scripts/resolve-updates.sh [--editors]
#   --editors  print only the editor and extension versions
#
# scripts/lib/dependency_updates.py compares these with the pins. Any lookup
# failure fails the whole script and prints nothing: there is then nothing to
# select from. Diagnostics go to stderr.
#
# VSCodium's build commit, which names its REH server directory, differs from
# upstream's commit metadata, so scripts/resolve-codium-commit.sh reads it
# from the release package instead.
#
# Requires: curl, jq, python3.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/base-images.sh
source "$ROOT/scripts/lib/base-images.sh"

editors_only=false
if [[ $# == 1 && $1 == --editors ]]; then
    editors_only=true
elif (($# != 0)); then
    echo 'usage: resolve-updates.sh [--editors]' >&2
    exit 2
fi

resolve_version() {
    local service=$1 filter=$2 response version
    shift 2
    if ! response="$(curl -fsSL --retry 3 --retry-all-errors --retry-max-time 45 \
        --connect-timeout 10 --max-time 60 "$@")"; then
        printf 'Error: could not fetch %s version after retries.\n' "$service" >&2
        return 1
    fi
    if ! version="$(jq -re "$filter" <<< "$response")" || [[ -z $version || $version == *$'\n'* ]]; then
        printf 'Error: %s returned a response without a valid version.\n' "$service" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

codium=$(resolve_version 'VSCodium GitHub releases' '.tag_name | strings' \
    https://api.github.com/repos/VSCodium/vscodium/releases/latest) || exit 1
code=$(resolve_version 'VS Code update API' '.productVersion | strings' \
    https://update.code.visualstudio.com/api/update/linux-x64/stable/latest) || exit 1
# flags=17 is IncludeVersions|IncludeVersionProperties: the versions array is
# newest-first, so the first entry without the PreRelease property is the
# latest stable release.
remote_ssh=$(resolve_version 'VS Code Marketplace Remote SSH' \
    '[.results[0].extensions[0].versions[]
        | select(([.properties[]?
            | select(.key == "Microsoft.VisualStudio.Code.PreRelease" and .value == "true")]
            | length) == 0)][0].version | strings' \
    -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json;api-version=3.0-preview.1' \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"ms-vscode-remote.remote-ssh"}]}],"flags":17}') || exit 1
open_remote_ssh=$(resolve_version 'Open VSX Open Remote SSH' '.version | strings' \
    https://open-vsx.org/api/jeanp413/open-remote-ssh) || exit 1
newest=$(printf 'CODIUM_VERSION=%s\nCODE_VERSION=%s\nREMOTE_SSH_VERSION=%s\nOPEN_REMOTE_SSH_VERSION=%s' \
    "$codium" "$code" "$remote_ssh" "$open_remote_ssh")

if [[ "$editors_only" == false ]]; then
    for image in "${BASE_IMAGES[@]}"; do
        if ! version=$(stable_image_version "$image"); then
            printf 'Error: could not identify the numbered stable %s image\n' "$image" >&2
            exit 1
        fi
        newest+=$'\n'"BASE_IMAGE_${image^^}=$image:$version"
    done
    go_series=$(bash "$ROOT/scripts/go-version.sh" --newest-series) || exit 1
    newest+=$'\n'"GO_SERIES=$go_series"
fi
printf '%s\n' "$newest"
