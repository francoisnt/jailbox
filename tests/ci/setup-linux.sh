#!/bin/bash
# Prepare an Ubuntu GitHub Actions host for jailbox tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/ci/setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

# JAILBOX_* overrides let the canary workflow install latest upstream versions
# without editing the pin file. Verifiers in setup-common.sh assert whatever
# ends up in these variables.
CODE_VERSION="${JAILBOX_CODE_VERSION:-$CODE_VERSION}"
CODIUM_VERSION="${JAILBOX_CODIUM_VERSION:-$CODIUM_VERSION}"
REMOTE_SSH_VERSION="${JAILBOX_REMOTE_SSH_VERSION:-$REMOTE_SSH_VERSION}"
OPEN_REMOTE_SSH_VERSION="${JAILBOX_OPEN_REMOTE_SSH_VERSION:-$OPEN_REMOTE_SSH_VERSION}"

install_base_tools() {
    local packages=(
        ca-certificates
        curl
        fuse-overlayfs
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
        "https://update.code.visualstudio.com/${CODE_VERSION}/linux-deb-x64/stable" \
        -o /tmp/code.deb
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/code.deb
    code --install-extension "ms-vscode-remote.remote-ssh@${REMOTE_SSH_VERSION}" --force
}

install_codium_editor() {
    # The VSCodium apt repo only serves latest; install the pinned .deb from
    # GitHub releases instead, and the extension from the deterministic
    # open-vsx VSIX URL (gallery @version negotiation is flaky).
    curl -fsSL \
        "https://github.com/VSCodium/vscodium/releases/download/${CODIUM_VERSION}/codium_${CODIUM_VERSION}_amd64.deb" \
        -o /tmp/codium.deb
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/codium.deb
    curl -fsSL \
        "https://open-vsx.org/api/jeanp413/open-remote-ssh/${OPEN_REMOTE_SSH_VERSION}/file/jeanp413.open-remote-ssh-${OPEN_REMOTE_SSH_VERSION}.vsix" \
        -o /tmp/open-remote-ssh.vsix
    codium --install-extension /tmp/open-remote-ssh.vsix --force
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
