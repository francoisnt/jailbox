#!/bin/bash
# New runtime files must ship and install without a second inventory.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/release-platform.sh
source "$ROOT/tests/lib/release-platform.sh"
platform=$(test_release_platform)
asset="jailbox-latest-$platform.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source"
cp -R "$ROOT/src" "$ROOT/scripts" "$ROOT/docs" "$tmp/source/"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$tmp/source/"
printf 'future runtime dependency\n' > "$tmp/source/src/container/runtime/lib/jailbox/future.data"
bash "$tmp/source/scripts/build-tarball.sh" v9.8.7 > "$tmp/build.log" 2>&1
tar -xzf "$tmp/source/dist/jailbox-v9.8.7-$platform.tar.gz" -C "$tmp"
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
    mkdir "$tmp/project-$mask"
    (cd "$tmp/project-$mask"; umask "$mask"; "$JAILBOX_BIN_DIR/jailbox" init)
    cmp "$ROOT/src/host/frontend/jailbox.conf.template" "$tmp/project-$mask/jailbox.conf"
done
# A checkout install uses explicitly built programs. Without them it fails
# clearly and leaves the working installation in place.
rm -rf "$tmp/source/src/libexec"
if "$installer_bash" "$tmp/source/src/install.sh" > "$tmp/install.log" 2>&1; then exit 1; fi
grep -Fq 'missing jailbox program libexec/jailbox-core' "$tmp/install.log"
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
[[ ! -e "$tmp/source/src/libexec" ]]
bash "$tmp/source/scripts/build-programs.sh" > "$tmp/build.log" 2>&1
"$installer_bash" "$tmp/source/src/install.sh" > "$tmp/install.log" 2>&1
[[ -x "$JAILBOX_INSTALL_DIR/libexec/jailbox-core" ]]
[[ -x "$JAILBOX_INSTALL_DIR/libexec/linux-amd64/jailbox-container" && ! -e "$JAILBOX_INSTALL_DIR/libexec/native" ]]
cmp "$ROOT/LICENSE" "$JAILBOX_INSTALL_DIR/LICENSE"
# Source checkout installation includes the same guides.
diff -r "$ROOT/docs" "$JAILBOX_INSTALL_DIR/docs"
# Save an older published installer, then advance the latest release assets.
# Streaming that saved script must retain its release even from a local source bundle.
mkdir "$tmp/download-tools"
cp "$ROOT/tests/fixtures/release-installer/curl.sh" "$tmp/download-tools/curl"
chmod 755 "$tmp/download-tools/curl"
cp -R "$tmp/source/dist" "$tmp/older-release"
export INSTALLER_PINNED_ASSETS="$tmp/older-release"
export INSTALLER_ASSETS="$tmp/source/dist" INSTALLER_REQUESTS="$tmp/requests"
bash "$tmp/source/scripts/build-tarball.sh" v9.8.8 > "$tmp/build.log" 2>&1
grep -Fxq 'RELEASE_VERSION=""' "$tmp/source/src/install.sh"
cmp "$bundle/install.sh" "$INSTALLER_PINNED_ASSETS/install.sh"
unset JAILBOX_RELEASE_BASE_URL
for mask in 0022 0002; do
    : > "$INSTALLER_REQUESTS"
    (cd "$tmp/source/src"; umask "$mask"
        cat "$INSTALLER_PINNED_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" "$installer_bash" > "$tmp/install.log" 2>&1)
    [[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
    cmp "$INSTALLER_PINNED_ASSETS/install.sh" "$JAILBOX_INSTALL_DIR/install.sh"
    diff -r "$ROOT/docs" "$JAILBOX_INSTALL_DIR/docs"
    printf '%s\n' \
        "https://github.com/francoisnt/jailbox/releases/download/v9.8.7/$asset" \
        'https://github.com/francoisnt/jailbox/releases/download/v9.8.7/SHA256SUMS' > "$tmp/expected-requests"
    cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
done
# A newly fetched installer selects its own newer release.
: > "$INSTALLER_REQUESTS"
cat "$INSTALLER_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" "$installer_bash" > "$tmp/install.log" 2>&1
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.8' ]]
printf '%s\n' \
    "https://github.com/francoisnt/jailbox/releases/download/v9.8.8/$asset" \
    'https://github.com/francoisnt/jailbox/releases/download/v9.8.8/SHA256SUMS' > "$tmp/expected-requests"
cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
# A saved installer run inside a project with its own VERSION file,
# container/ and host/ directories still downloads its release instead of
# treating the project as a local bundle.
mkdir -p "$tmp/saved-project/container" "$tmp/saved-project/host"
printf '9.8.7\n' > "$tmp/saved-project/VERSION"
cp "$INSTALLER_ASSETS/install.sh" "$tmp/saved-project/install.sh"
: > "$INSTALLER_REQUESTS"
(cd "$tmp/saved-project" && PATH="$tmp/download-tools:$PATH" "$installer_bash" install.sh > "$tmp/install.log" 2>&1)
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.8' ]]
cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
# A corrupt download must fail before replacing the installed release.
printf 'corrupt\n' >> "$INSTALLER_ASSETS/$asset"
if cat "$INSTALLER_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" "$installer_bash" > "$tmp/install.log" 2>&1; then exit 1; fi
grep -Fq "checksum verification failed for $asset" "$tmp/install.log"
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.8' ]]
# Explicit pinning selects the old release's alias and checksum file together.
: > "$INSTALLER_REQUESTS"
cat "$INSTALLER_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" \
    JAILBOX_RELEASE_BASE_URL=https://github.com/francoisnt/jailbox/releases/download/v9.8.7 \
    "$installer_bash" > "$tmp/install.log" 2>&1
[[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
printf '%s\n' \
    "https://github.com/francoisnt/jailbox/releases/download/v9.8.7/$asset" \
    'https://github.com/francoisnt/jailbox/releases/download/v9.8.7/SHA256SUMS' > "$tmp/expected-requests"
cmp "$tmp/expected-requests" "$INSTALLER_REQUESTS"
# Unsupported platforms fail before making any request or replacing a release.
cat > "$tmp/download-tools/uname" <<'STUB'
#!/bin/bash
case "$1" in -s) printf '%s\n' "$TEST_OS" ;; -m) printf '%s\n' "$TEST_ARCH" ;; esac
STUB
chmod 755 "$tmp/download-tools/uname"
for scenario in 'FreeBSD x86_64' 'Linux riscv64'; do
    read -r TEST_OS TEST_ARCH <<< "$scenario"
    : > "$INSTALLER_REQUESTS"
    if cat "$INSTALLER_PINNED_ASSETS/install.sh" | PATH="$tmp/download-tools:$PATH" TEST_OS="$TEST_OS" TEST_ARCH="$TEST_ARCH" "$installer_bash" > "$tmp/out" 2>&1; then
        exit 1
    fi
    grep -Fq 'unsupported host' "$tmp/out"
    [[ ! -s "$INSTALLER_REQUESTS" ]]
done
rm "$tmp/download-tools/uname"
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
assert_preserved_install() {
    [[ $(cat "$JAILBOX_INSTALL_DIR/preserved") == keep && ! -e "$JAILBOX_INSTALL_DIR/partial" ]]
    [[ $("$JAILBOX_BIN_DIR/jailbox" --version) == 'jailbox 9.8.7' ]]
    [[ -z $(find "$tmp/share" -maxdepth 1 -name '.jailbox.install.*' -print) ]]
}
assert_preserved_install
rm "$tmp/tools/cp"

# Fail after moving the old bundle aside, then after replacing it while
# publishing a command in a new bin directory.
cat > "$tmp/tools/mv" <<'STUB'
#!/bin/bash
if [[ -f "$1/.jailbox-install" && ! -e "$1/preserved" ]]; then
    exit 23
fi
exec /bin/mv "$@"
STUB
cat > "$tmp/tools/ln" <<'STUB'
#!/bin/bash
exit 24
STUB
chmod 755 "$tmp/tools/mv" "$tmp/tools/ln"
for mask in 0022 0002; do
    if (umask "$mask"; PATH="$tmp/tools:$PATH" "$installer_bash" "$tmp/source/src/install.sh") > "$tmp/out" 2>&1; then
        exit 1
    fi
    grep -Fq 'could not publish the installation' "$tmp/out"
    assert_preserved_install
done
rm "$tmp/tools/mv"
for mask in 0022 0002; do
    if (umask "$mask"; PATH="$tmp/tools:$PATH" JAILBOX_BIN_DIR="$tmp/alternate-bin" \
        "$installer_bash" "$tmp/source/src/install.sh") > "$tmp/out" 2>&1; then
        exit 1
    fi
    grep -Fq 'could not publish the jailbox command' "$tmp/out"
    [[ ! -L "$tmp/alternate-bin/jailbox" ]]
    assert_preserved_install
done
echo 'PASS: recursive packaging/installation and preservation after failed updates'
