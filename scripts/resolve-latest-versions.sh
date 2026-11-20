#!/bin/bash
# Resolve latest upstream versions and compare against the versions.env pins.
#
# Prints KEY=value lines for $GITHUB_OUTPUT (diagnostics go to stderr):
#   CODIUM_VERSION            latest VSCodium release tag (GitHub API)
#   CODE_VERSION              latest VS Code stable (update API)
#   REMOTE_SSH_VERSION        latest stable ms-vscode-remote.remote-ssh (marketplace)
#   OPEN_REMOTE_SSH_VERSION   latest jeanp413.open-remote-ssh (open-vsx)
#   has_new                   true when any latest differs from its pin
#
# The matching CODIUM_COMMIT is deliberately not resolved here: VSCodium's
# build commit (which names the REH server dir) differs from upstream's
# commit metadata, so the canary reads it post-install via `codium --version`.
#
# Requires: curl, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=versions.env
source "$JAILBOX_DIR/versions.env"

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

latest_codium="$(resolve_version 'VSCodium GitHub releases' '.tag_name | strings' \
    https://api.github.com/repos/VSCodium/vscodium/releases/latest)"

latest_code="$(resolve_version 'VS Code update API' '.productVersion | strings' \
    https://update.code.visualstudio.com/api/update/linux-x64/stable/latest)"

# flags=17 is IncludeVersions|IncludeVersionProperties: the versions array is
# newest-first, so the first entry without the PreRelease property is the
# latest stable release.
latest_remote_ssh="$(resolve_version 'VS Code Marketplace Remote SSH' \
    '[.results[0].extensions[0].versions[]
        | select(([.properties[]?
            | select(.key == "Microsoft.VisualStudio.Code.PreRelease" and .value == "true")]
            | length) == 0)][0].version | strings' \
    -X POST 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json;api-version=3.0-preview.1' \
    -d '{"filters":[{"criteria":[{"filterType":7,"value":"ms-vscode-remote.remote-ssh"}]}],"flags":17}')"

latest_open_remote_ssh="$(resolve_version 'Open VSX Open Remote SSH' '.version | strings' \
    https://open-vsx.org/api/jeanp413/open-remote-ssh)"

has_new=false
[[ "$latest_codium" == "$CODIUM_VERSION" ]] || has_new=true
[[ "$latest_code" == "$CODE_VERSION" ]] || has_new=true
[[ "$latest_remote_ssh" == "$REMOTE_SSH_VERSION" ]] || has_new=true
[[ "$latest_open_remote_ssh" == "$OPEN_REMOTE_SSH_VERSION" ]] || has_new=true

{
    echo "pinned: codium=$CODIUM_VERSION code=$CODE_VERSION remote-ssh=$REMOTE_SSH_VERSION open-remote-ssh=$OPEN_REMOTE_SSH_VERSION"
    echo "latest: codium=$latest_codium code=$latest_code remote-ssh=$latest_remote_ssh open-remote-ssh=$latest_open_remote_ssh"
    echo "has_new: $has_new"
} >&2

printf 'CODIUM_VERSION=%s\n' "$latest_codium"
printf 'CODE_VERSION=%s\n' "$latest_code"
printf 'REMOTE_SSH_VERSION=%s\n' "$latest_remote_ssh"
printf 'OPEN_REMOTE_SSH_VERSION=%s\n' "$latest_open_remote_ssh"
printf 'has_new=%s\n' "$has_new"
