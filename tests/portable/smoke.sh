#!/bin/bash
# Portable smoke checks: syntax, release tarball, and install lifecycle.
#
# Intentionally avoids Podman, editor GUI, and Linux-container runtime
# assertions. Runs on any supported host OS without prior setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$JAILBOX_DIR"

tmp_dirs=()
TMP_PARENT="$JAILBOX_DIR/.portable-smoke-tmp"

cleanup() {
    local dir

    for dir in "${tmp_dirs[@]+"${tmp_dirs[@]}"}"; do
        rm -rf "$dir"
    done
    rmdir "$TMP_PARENT" 2>/dev/null || true
    rm -f dist/jailbox-v9.9.9.tar.gz dist/jailbox-latest.tar.gz
}
trap cleanup EXIT

new_tmp_dir() {
    local varname="$1"
    mkdir -p "$TMP_PARENT"
    local d
    d="$(mktemp -d "$TMP_PARENT/jailbox-smoke-test.XXXXXX")"
    tmp_dirs+=("$d")
    printf -v "$varname" '%s' "$d"
}

section() {
    printf '\n== %s ==\n' "$1"
}

syntax_check() {
    section "syntax"
    bash -n jailbox install.sh host/*.sh scripts/*.sh tests/ci/*.sh tests/e2e/*.sh tests/integration/*.sh tests/lib/*.sh tests/portable/*.sh tests/unit/*.sh tests/run
    bash -n container/downloader-proxy-manager.sh
    sh -n container/setup.sh container/entrypoint.sh
}

reject_macos_system_bash() {
    local output status

    [[ "$(uname -s)" == "Darwin" ]] || return 0

    set +e
    output="$(/bin/bash jailbox --help 2>&1)"
    status="$?"
    set -e

    [[ "$status" -ne 0 ]]
    grep -Fq "Error: jailbox requires Bash 4.4 or newer (found 3.2." <<<"$output"
    grep -Fq "Install it on macOS with: brew install bash" <<<"$output"
}

build_release_tarball() {
    section "release tarball"
    bash scripts/build-tarball.sh v9.9.9
    test -f dist/jailbox-v9.9.9.tar.gz
    test -f dist/jailbox-latest.tar.gz
    cmp -s dist/jailbox-v9.9.9.tar.gz dist/jailbox-latest.tar.gz
    tar -tzf dist/jailbox-latest.tar.gz | grep -Fx jailbox-v9.9.9/install.sh
}

smoke_install_update_uninstall() {
    local tmp

    section "install update uninstall"
    new_tmp_dir tmp

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh
    "$tmp/bin/jailbox" --help >/dev/null
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox dev' ]]

    tar -xzf "$JAILBOX_DIR/dist/jailbox-v9.9.9.tar.gz" -C "$tmp"
    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" bash "$tmp/jailbox-v9.9.9/install.sh" >/dev/null
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox 9.9.9' ]]
    cmp "$tmp/share/jailbox/VERSION" "$tmp/jailbox-v9.9.9/VERSION"

    # Updating from another stamped tree replaces the installed identity.
    printf '9.9.10\n' > "$tmp/jailbox-v9.9.9/VERSION"
    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" bash "$tmp/jailbox-v9.9.9/install.sh" >/dev/null
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox 9.9.10' ]]

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh >/dev/null
    test -L "$tmp/bin/jailbox"
    test -f "$tmp/share/jailbox/.jailbox-install"
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox dev' ]]
    [[ ! -e "$tmp/share/jailbox/VERSION" ]]

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" "$tmp/share/jailbox/install.sh" --uninstall
    test ! -e "$tmp/share/jailbox"
    test ! -e "$tmp/bin/jailbox"
}

refuse_unmanaged_update_target() {
    local tmp

    section "unmanaged update refusal"
    new_tmp_dir tmp

    mkdir -p "$tmp/share/jailbox" "$tmp/bin"
    printf x > "$tmp/share/jailbox/user-file"
    if JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh >"$tmp/out" 2>&1; then
        cat "$tmp/out"
        return 1
    fi
    grep -q "refusing to replace unmanaged install directory" "$tmp/out"
}

main() {
    syntax_check
    reject_macos_system_bash
    build_release_tarball
    smoke_install_update_uninstall
    refuse_unmanaged_update_target
    refuse_failed_target_discovery
}

refuse_failed_target_discovery() {
    local tmp partial
    section "failed target discovery refusal"
    new_tmp_dir tmp
    printf 'parent file\n' > "$tmp/parent"
    mkdir "$tmp/bin"
    ln -s "$tmp/original" "$tmp/bin/jailbox"
    if JAILBOX_INSTALL_DIR="$tmp/parent/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh > "$tmp/out" 2>&1; then return 1; fi
    grep -q 'could not resolve install target' "$tmp/out"
    [[ $(cat "$tmp/parent") == 'parent file' && $(readlink "$tmp/bin/jailbox") == "$tmp/original" ]]
    mkdir -p "$tmp/share/jailbox" "$tmp/tools"
    printf 'keep\n' > "$tmp/share/jailbox/user-file"
    cat > "$tmp/tools/find" <<'STUB'
#!/bin/bash
printf '%s' "$PARTIAL"
exit 42
STUB
    chmod 755 "$tmp/tools/find"
    for partial in '' user-file; do
        if PATH="$tmp/tools:$PATH" PARTIAL="$partial" JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh > "$tmp/out" 2>&1; then return 1; fi
        grep -q 'could not inspect install target' "$tmp/out"
        [[ $(cat "$tmp/share/jailbox/user-file") == keep && $(readlink "$tmp/bin/jailbox") == "$tmp/original" ]]
    done
}

main "$@"
