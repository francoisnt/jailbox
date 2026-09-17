#!/bin/bash
set -euo pipefail
for root in "$HOME/.vscodium-server" "$HOME/.vscode-server"; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 8 -type f \( -name '*.log' -o -name 'log.txt' \) \
        -exec awk '/Launched Extension Host Process/' {} +
done
