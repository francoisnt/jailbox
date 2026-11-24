#!/bin/bash
# Print the build commit of VSCodium VERSION, which names its REH server
# directory. Release metadata carries Microsoft's commit instead, so read the
# commit from the product.json inside the release package.
#
# Usage: scripts/resolve-codium-commit.sh VERSION
# Requires: curl, python3.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

version=${1-}
if (($# != 1)) || [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo 'usage: resolve-codium-commit.sh VERSION' >&2
    exit 2
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

curl -fsSL --retry 3 --retry-all-errors --retry-max-time 120 --connect-timeout 10 \
    "https://github.com/VSCodium/vscodium/releases/download/${version}/VSCodium-linux-x64-${version}.tar.gz" \
    -o "$work/codium.tar.gz"
python3 "$ROOT/scripts/lib/dependency_updates.py" codium-commit "$work/codium.tar.gz"
