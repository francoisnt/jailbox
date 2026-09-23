#!/bin/bash
# New runtime files must ship and install without a second inventory.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source"
cp -R "$ROOT/src" "$ROOT/scripts" "$tmp/source/"
cp "$ROOT/README.md" "$tmp/source/"
printf 'future runtime dependency\n' > "$tmp/source/src/container/runtime/lib/jailbox/future.data"
bash "$tmp/source/scripts/build-tarball.sh" v9.8.7 > "$tmp/build.log" 2>&1
tar -xzf "$tmp/source/dist/jailbox-v9.8.7.tar.gz" -C "$tmp"
bundle=$tmp/jailbox-v9.8.7
cmp "$tmp/source/src/container/runtime/lib/jailbox/future.data" "$bundle/container/runtime/lib/jailbox/future.data"
[[ ! -e "$bundle/ARCHITECTURE.md" && ! -e "$bundle/CONTRIBUTING.md" ]]
if grep -Eq 'ARCHITECTURE\.md|CONTRIBUTING\.md' "$bundle/README.md"; then exit 1; fi
export JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin"
installer_bash=bash
if [[ $(uname -s) == Darwin ]]; then installer_bash=/bin/bash; fi
for mask in 0022 0002; do
    (umask "$mask"; "$installer_bash" "$bundle/install.sh" > "$tmp/install.log" 2>&1)
    cmp "$bundle/container/runtime/lib/jailbox/future.data" "$JAILBOX_INSTALL_DIR/container/runtime/lib/jailbox/future.data"
    cmp "$bundle/README.md" "$JAILBOX_INSTALL_DIR/README.md"
    [[ ! -e "$JAILBOX_INSTALL_DIR/ARCHITECTURE.md" && ! -e "$JAILBOX_INSTALL_DIR/CONTRIBUTING.md" ]]
done
printf 'keep\n' > "$JAILBOX_INSTALL_DIR/preserved"
# Simulate a copy that writes partial output before failing. Neither that output
# nor an empty staging directory may replace the previous installation.
mkdir "$tmp/tools"
cat > "$tmp/tools/cp" <<'STUB'
#!/bin/bash
printf 'partial\n' > "${@: -1}/partial"
exit 42
STUB
chmod 755 "$tmp/tools/cp"
if PATH="$tmp/tools:$PATH" "$installer_bash" "$bundle/install.sh" > "$tmp/out" 2>&1; then exit 1; fi
grep -Fq 'could not copy installer bundle' "$tmp/out"
[[ $(cat "$JAILBOX_INSTALL_DIR/preserved") == keep && ! -e "$JAILBOX_INSTALL_DIR/partial" ]]
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
[[ -z $(find "$tmp/share" -maxdepth 1 -name '.jailbox.install.*' -print) ]]
echo 'PASS: recursive packaging/installation and preservation after failed copying'
