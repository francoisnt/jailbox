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
    bash -n jailbox install.sh host/*.sh scripts/*.sh tests/ci/*.sh tests/portable/*.sh tests/unit/*.sh tests/run
    bash -n container/downloader-proxy-manager.sh
    sh -n container/setup.sh container/entrypoint.sh
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

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./install.sh >/dev/null
    test -L "$tmp/bin/jailbox"
    test -f "$tmp/share/jailbox/.jailbox-install"

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
    build_release_tarball
    smoke_install_update_uninstall
    refuse_unmanaged_update_target
}

main "$@"
