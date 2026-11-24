#!/bin/bash
# Prepare an Ubuntu GitHub Actions host for jailbox tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/ci/setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

# shellcheck source=versions.env
source "$ROOT_DIR/versions.env"

# The pins decide the editor versions. To test other versions, apply them to
# the checkout first (tests/ci/editor-gate.sh setup does). Verifiers in
# setup-common.sh assert these exact versions.

install_base_tools() {
    local packages=(
        ca-certificates
        curl
        fuse-overlayfs
        openssh-client
        podman
        python3
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
