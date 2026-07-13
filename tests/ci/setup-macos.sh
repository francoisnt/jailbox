#!/bin/bash
# Prepare a macOS host for jailbox tests — manual local-Mac convenience only.
#
# Not run in CI: GitHub macOS runners lack the hypervisor entitlement, so
# podman machine cannot start (see 999d314). Editor installs here are
# intentionally floating (brew latest), unlike the pinned Linux CI path;
# the setup-common.sh verifiers only check presence when pins are unset.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN_MACHINE_NAME="${PODMAN_MACHINE_NAME:-jailbox-ci}"

# shellcheck source=tests/ci/setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

prepend_path() {
    local path="$1"

    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$path" >> "$GITHUB_PATH"
    fi
    export PATH="$path:$PATH"
}

install_base_tools() {
    HOMEBREW_NO_AUTO_UPDATE=1 brew install coreutils podman qemu shellcheck
    prepend_path "$(brew --prefix coreutils)/libexec/gnubin"
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
    if ! podman machine inspect "$PODMAN_MACHINE_NAME" >/dev/null 2>&1; then
        CONTAINERS_MACHINE_PROVIDER=qemu podman machine init --cpus 2 --memory 4096 --disk-size 30 "$PODMAN_MACHINE_NAME"
    fi

    if podman machine inspect "$PODMAN_MACHINE_NAME" --format '{{.State}}' 2>/dev/null | grep -qi running; then
        return 0
    fi

    podman machine start "$PODMAN_MACHINE_NAME"
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

main "$@"
