#!/bin/bash
set -eu
server_bin=""
for candidate in "$HOME/.vscodium-server/bin"/*/bin/codium-server \
                 "$HOME/.vscode-server/bin"/*/bin/code-server \
                 "$HOME/.vscodium-server/cli/servers"/*/server/bin/codium-server \
                 "$HOME/.vscode-server/cli/servers"/*/server/bin/code-server; do
    if [ -x "$candidate" ]; then
        server_bin="$candidate"
        break
    fi
done
[ -n "$server_bin" ] || { echo "no remote editor server CLI found" >&2; exit 1; }
"$server_bin" --install-extension /tmp/jailbox-editor-proof.vsix --force
