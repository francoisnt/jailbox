#!/bin/bash
# Install an already validated platform archive on its native host.
set -euo pipefail
[[ $# = 3 ]] || exit 2
dist=$1 version=$2 platform=$3
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
tar -xzf "$dist/jailbox-$version-$platform.tar.gz" -C "$tmp"
export JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin"
/bin/bash "$tmp/jailbox-$version/install.sh"
[[ $("$tmp/bin/jailbox" --version) = "jailbox ${version#v}" ]]
[[ $("$JAILBOX_INSTALL_DIR/libexec/jailbox-core" "${version#v}" encode 'release smoke' pwd) = cHdkAA== ]]
for arch in amd64 arm64; do
    [[ -x "$JAILBOX_INSTALL_DIR/libexec/linux-$arch/jailbox-container" ]]
done
/bin/bash "$JAILBOX_INSTALL_DIR/install.sh" --uninstall
[[ ! -e "$JAILBOX_INSTALL_DIR" && ! -e "$tmp/bin/jailbox" ]]
