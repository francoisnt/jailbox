#!/bin/bash
# Shared helpers for OS-specific CI setup scripts.

# shellcheck disable=SC2034  # consumed by OS-specific setup scripts after source
WITH_EDITORS=false

prepend_path() {
    local path="$1"

    if [[ -n "${GITHUB_PATH:-}" ]]; then
        printf '%s\n' "$path" >> "$GITHUB_PATH"
    fi
    export PATH="$path:$PATH"
}

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

verify_portable_tools() {
    python3 --version
    realpath --version
    find . --version
    shellcheck --version
}

verify_base_tools() {
    verify_portable_tools
    timeout --version
    podman info
    ssh -V
}

# Marketplace extension installation can fail with a temporary server error.
# Retry the identical pinned CLI request, without accepting another version.
install_extension_with_retry() {
    local attempt status=0 delay
    for attempt in 1 2 3; do
        if "$@"; then return 0; else status=$?; fi
        if ((attempt < 3)); then
            delay=$((attempt * 5))
            printf 'Extension installation failed (attempt %d/3, exit %d); retrying in %ds.\n' \
                "$attempt" "$status" "$delay" >&2
            sleep "$delay" || return $?
        fi
    done
    return "$status"
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
