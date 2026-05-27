#!/bin/bash
# Prepare an Ubuntu GitHub Actions host for jailbox tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/ci/setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

install_base_tools() {
    local packages=(
        ca-certificates
        curl
        fuse-overlayfs
        gnupg
        openssh-client
        podman
        shellcheck
        slirp4netns
        uidmap
        wget
        xauth
        xvfb
    )

    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_code_editor() {
    curl -fsSL \
        https://update.code.visualstudio.com/latest/linux-deb-x64/stable \
        -o /tmp/code.deb
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/code.deb
    code --install-extension ms-vscode-remote.remote-ssh --force
}

install_codium_editor() {
    curl -fsSL https://repo.vscodium.dev/vscodium.gpg \
        | gpg --dearmor \
        | sudo dd of=/usr/share/keyrings/vscodium.gpg
    sudo curl --output-dir /etc/apt/sources.list.d \
        -LO https://repo.vscodium.dev/vscodium.sources
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y codium
    codium --install-extension jeanp413.open-remote-ssh --force
}

main() {
    parse_setup_args "$@"
    cd "$ROOT_DIR"

    install_base_tools
    verify_base_tools
    if [[ "$WITH_EDITORS" == true ]]; then
        install_code_editor
        install_codium_editor
        verify_code_editor
        verify_codium_editor
    fi
}

main "$@"
