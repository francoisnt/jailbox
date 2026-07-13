#!/bin/bash
# Shared helpers for OS-specific CI setup scripts.

# shellcheck disable=SC2034  # consumed by OS-specific setup scripts after source
WITH_EDITORS=false

setup_usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [--with-editors]

Installs test dependencies. Pass --with-editors to also install VS Code,
VSCodium, and their Remote SSH extensions for editor smoke tests.
EOF_USAGE
}

parse_setup_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --with-editors)
                WITH_EDITORS=true
                shift
                ;;
            --help|-h)
                setup_usage
                exit 0
                ;;
            *)
                setup_usage >&2
                exit 2
                ;;
        esac
    done
}

verify_base_tools() {
    realpath --version
    timeout --version
    podman info
    ssh -V
    shellcheck --version
}

# When the pin variables are set (Linux sources versions.env), the verifiers
# assert exact versions; without them (macOS installs floating via brew) they
# only check presence.
verify_code_editor() {
    code --version
    if [[ -n "${CODE_VERSION:-}" ]]; then
        code --version | head -1 | grep -Fx "$CODE_VERSION"
    fi
    if [[ -n "${REMOTE_SSH_VERSION:-}" ]]; then
        code --list-extensions --show-versions \
            | grep -Fx "ms-vscode-remote.remote-ssh@${REMOTE_SSH_VERSION}"
    else
        code --list-extensions | grep -Fx ms-vscode-remote.remote-ssh
    fi
}

verify_codium_editor() {
    codium --version
    if [[ -n "${CODIUM_VERSION:-}" ]]; then
        codium --version | head -1 | grep -Fx "$CODIUM_VERSION"
    fi
    if [[ -n "${OPEN_REMOTE_SSH_VERSION:-}" ]]; then
        codium --list-extensions --show-versions \
            | grep -Fx "jeanp413.open-remote-ssh@${OPEN_REMOTE_SSH_VERSION}"
    else
        codium --list-extensions | grep -Fx jeanp413.open-remote-ssh
    fi
}

