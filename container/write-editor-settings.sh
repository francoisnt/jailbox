#!/bin/bash
set -euo pipefail
mkdir -p "$HOME/.vscodium-server/data/Machine" "$HOME/.vscode-server/data/Machine"
tee "$HOME/.vscodium-server/data/Machine/settings.json" \
    > "$HOME/.vscode-server/data/Machine/settings.json"
