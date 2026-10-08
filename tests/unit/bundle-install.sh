#!/bin/bash
# New runtime files must ship and install without a second inventory.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source"
cp -R "$ROOT/src" "$ROOT/scripts" "$ROOT/docs" "$tmp/source/"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$tmp/source/"
printf 'future runtime dependency\n' > "$tmp/source/src/container/runtime/lib/jailbox/future.data"
bash "$tmp/source/scripts/build-tarball.sh" v9.8.7 > "$tmp/build.log" 2>&1
tar -xzf "$tmp/source/dist/jailbox-v9.8.7.tar.gz" -C "$tmp"
bundle=$tmp/jailbox-v9.8.7
cmp "$ROOT/LICENSE" "$bundle/LICENSE"
diff -r "$ROOT/docs" "$bundle/docs"
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
    diff -r "$bundle/docs" "$JAILBOX_INSTALL_DIR/docs"
    cmp "$ROOT/LICENSE" "$JAILBOX_INSTALL_DIR/LICENSE"
    [[ ! -e "$JAILBOX_INSTALL_DIR/ARCHITECTURE.md" && ! -e "$JAILBOX_INSTALL_DIR/CONTRIBUTING.md" ]]
done
"$installer_bash" "$tmp/source/src/install.sh" > "$tmp/install.log" 2>&1
cmp "$ROOT/LICENSE" "$JAILBOX_INSTALL_DIR/LICENSE"
# Source checkout installation includes the same guides.
diff -r "$ROOT/docs" "$JAILBOX_INSTALL_DIR/docs"
# Save an older published installer, then advance the latest release assets.
# Streaming that saved script must install latest even from a local source bundle.
mkdir "$tmp/download-tools"
cp "$ROOT/tests/fixtures/release-installer/curl.sh" "$tmp/download-tools/curl"
chmod 755 "$tmp/download-tools/curl"
cp -R "$tmp/source/dist" "$tmp/older-release"
export INSTALLER_PINNED_ASSETS="$tmp/older-release"
export INSTALLER_ASSETS="$tmp/source/dist" INSTALLER_REQUESTS="$tmp/requests"
bash "$tmp/source/scripts/build-tarball.sh" v9.8.8 > "$tmp/build.log" 2>&1
cmp "$ROOT/src/install.sh" "$INSTALLER_ASSETS/install.sh"
unset JAILBOX_RELEASE_BASE_URL
for mask in 0022 0002; do
    : > "$INSTALLER_REQUESTS"
    (cd "$tmp/source/src"; umask "$mask"
        cat "$INSTALLER_PINNED_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" "$installer_bash" > "$tmp/install.log" 2>&1)
    [[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.8' ]]
    cmp "$INSTALLER_ASSETS/install.sh" "$JAILBOX_INSTALL_DIR/install.sh"
    diff -r "$ROOT/docs" "$JAILBOX_INSTALL_DIR/docs"
    printf '%s\n' \
        'https://github.com/francoisnt/jailbox/releases/latest/download/jailbox-latest.tar.gz' \
        'https://github.com/francoisnt/jailbox/releases/latest/download/SHA256SUMS' > "$tmp/expected-requests"
    cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
done
# A corrupt download must fail before replacing the installed release.
printf 'corrupt\n' >> "$INSTALLER_ASSETS/jailbox-latest.tar.gz"
if cat "$INSTALLER_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" "$installer_bash" > "$tmp/install.log" 2>&1; then exit 1; fi
grep -Fq 'checksum verification failed for jailbox-latest.tar.gz' "$tmp/install.log"
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.8' ]]
# Explicit pinning selects the old release's alias and checksum file together.
: > "$INSTALLER_REQUESTS"
cat "$INSTALLER_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" \
    JAILBOX_RELEASE_BASE_URL=https://github.com/francoisnt/jailbox/releases/download/v9.8.7 \
    "$installer_bash" > "$tmp/install.log" 2>&1
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
printf '%s\n' \
    'https://github.com/francoisnt/jailbox/releases/download/v9.8.7/jailbox-latest.tar.gz' \
    'https://github.com/francoisnt/jailbox/releases/download/v9.8.7/SHA256SUMS' > "$tmp/expected-requests"
cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
# Restore the versioned installation for the failure checks below.
"$installer_bash" "$bundle/install.sh" > "$tmp/install.log" 2>&1
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
