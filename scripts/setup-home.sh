#!/usr/bin/env bash
set -euo pipefail

# Initialize a jailbox development home with the standalone Codex CLI.
: "${HOME:?HOME must be set}"

installer=$(mktemp) || exit 1
trap 'rm -f -- "$installer"' EXIT

curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$installer" https://chatgpt.com/codex/install.sh || exit $?

CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$HOME/.local/bin" \
    sh "$installer" </dev/null
