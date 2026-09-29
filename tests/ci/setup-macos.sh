#!/bin/bash
# Prepare an Intel CI runner or physical Mac for the Podman Machine smoke test.
# GitHub's ARM runners cannot run the VM; CI selects macos-26-intel explicitly.
# Editor installs here are
# intentionally floating (brew latest), unlike the pinned Linux CI path;
# the setup-common.sh verifiers only check presence when pins are unset.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN_MACHINE_NAME="${PODMAN_MACHINE_NAME:-jailbox-ci}"
export CONTAINERS_MACHINE_PROVIDER=applehv

# shellcheck source=tests/ci/setup-portable.sh
source "$SCRIPT_DIR/setup-portable.sh"

install_base_tools() {
    HOMEBREW_NO_AUTO_UPDATE=1 brew install podman
}

wait_for_podman_machine() {
    local attempts
    attempts=0
    while (( attempts < 30 )); do
        podman info >/dev/null 2>&1 && return 0
        attempts=$(( attempts + 1 ))
        sleep 2
    done
    printf 'podman machine not ready after 60 seconds\n' >&2
    return 1
}

start_podman_machine() {
    local machines state
    [[ "$PODMAN_MACHINE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || return 1
    machines=$(podman machine list --format '{{.Name}}') || return 1
    if ! grep -Fxq "$PODMAN_MACHINE_NAME" <<< "$machines"; then
        podman machine init --rootful=false --cpus 2 --memory 6144 --disk-size 30 \
            --volume "$HOME:$HOME" "$PODMAN_MACHINE_NAME" || return 1
    fi

    # Target this machine's rootless connection without changing the user's
    # default connection or accidentally testing another running engine.
    export CONTAINER_CONNECTION="$PODMAN_MACHINE_NAME"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf 'CONTAINER_CONNECTION=%s\nCONTAINERS_MACHINE_PROVIDER=applehv\n' \
            "$PODMAN_MACHINE_NAME" >> "$GITHUB_ENV" || return 1
    fi
    state=$(podman machine inspect "$PODMAN_MACHINE_NAME" --format '{{.State}}') || return 1
    if [[ "$state" != running ]]; then
        podman machine start --update-connection=false "$PODMAN_MACHINE_NAME" || return 1
    fi
    wait_for_podman_machine
}

install_code_editor() {
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask visual-studio-code
    prepend_path "$(brew --prefix)/bin"
    code --install-extension ms-vscode-remote.remote-ssh --force
}

install_codium_editor() {
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask vscodium
    prepend_path "$(brew --prefix)/bin"
    codium --install-extension jeanp413.open-remote-ssh --force
}

main() {
    parse_setup_args "$@"
    cd "$ROOT_DIR"

    install_portable_tools
    install_base_tools
    start_podman_machine
    verify_base_tools
    if [[ "$WITH_EDITORS" == true ]]; then
        install_code_editor
        install_codium_editor
        verify_code_editor
        verify_codium_editor
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
