#!/bin/bash
# Portable smoke checks: syntax, release tarball, and install lifecycle.
#
# Intentionally avoids Podman, editor GUI, and Linux-container runtime
# assertions. Runs on any supported host OS without prior setup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=tests/lib/release-platform.sh
source "$JAILBOX_DIR/tests/lib/release-platform.sh"
platform=$(test_release_platform)
release_version=v9.9.9
archive="jailbox-$release_version-$platform.tar.gz"
latest="jailbox-latest-$platform.tar.gz"

cd "$JAILBOX_DIR"

tmp_dirs=()
TMP_PARENT="$JAILBOX_DIR/.portable-smoke-tmp"

cleanup() {
    local dir

    for dir in "${tmp_dirs[@]+"${tmp_dirs[@]}"}"; do
        rm -rf "$dir"
    done
    rmdir "$TMP_PARENT" 2>/dev/null || true

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

reject_macos_system_bash() {
    local output status

    [[ "$(uname -s)" == "Darwin" ]] || return 0
    /bin/bash -n src/install.sh || return 1
    /bin/bash -n src/host/prerequisites.sh || return 1

    set +e
    output="$(/bin/bash src/jailbox --help 2>&1)"
    status="$?"
    set -e

    [[ "$status" -ne 0 ]]
    grep -Fq "Error: jailbox requires Bash 4.4 or newer (found 3.2." <<<"$output"
    grep -Fq "Install it on macOS with: brew install bash" <<<"$output"
}

build_release_tarball() {
    section "release tarball"
    bash scripts/build-tarball.sh v9.9.9
    local list path
    list=$(tar -tzf "dist/$latest")
    for path in libexec/jailbox-core libexec/linux-amd64/jailbox-container libexec/linux-arm64/jailbox-container install.sh public-api.sh; do
        grep -Fxq "jailbox-$release_version/$path" <<< "$list"
    done
    cmp -s "dist/$archive" "dist/$latest"
    if grep -Eq '(^jailbox-v9\.9\.9/(src|scripts|tests|plans)/|[.](go|py)$|/go[.]mod$|/go[.]sum$)' <<< "$list"; then
        return 1
    fi
    bash "$SCRIPT_DIR/release-install.sh" "$JAILBOX_DIR/dist" "$release_version" "$platform"
}

smoke_install_update_uninstall() {
    local tmp

    section "install update uninstall"
    new_tmp_dir tmp

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./src/install.sh
    "$tmp/bin/jailbox" --help >/dev/null
    cmp README.md "$tmp/share/jailbox/README.md"
    diff -r docs "$tmp/share/jailbox/docs"
    cmp src/install.sh "$tmp/share/jailbox/install.sh"
    test -x "$tmp/share/jailbox/libexec/jailbox-core"
    test -x "$tmp/share/jailbox/libexec/linux-amd64/jailbox-container"
    test -x "$tmp/share/jailbox/libexec/linux-arm64/jailbox-container"
    test ! -e "$tmp/share/jailbox/go.mod"
    test -r "$tmp/share/jailbox/container/runtime/lib/jailbox/readonly-mount.awk"
    test -r "$tmp/share/jailbox/container/runtime/lib/jailbox/authentication-mount.awk"
    test -r "$tmp/share/jailbox/container/runtime/lib/jailbox/process-hardening.awk"
    test -r "$tmp/share/jailbox/container/runtime/bin/jailbox-write-editor-settings"
    test -r "$tmp/share/jailbox/container/checks/proxy-route.awk"
    test -r "$tmp/share/jailbox/container/checks/validate-session.sh"
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox dev' ]]

    tar -xzf "$JAILBOX_DIR/dist/$archive" -C "$tmp"
    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" bash "$tmp/jailbox-v9.9.9/install.sh" >/dev/null
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox 9.9.9' ]]
    "$tmp/bin/jailbox" config-schema > "$tmp/schema"
    grep -Fxq $'HOME_SETUP_SCRIPT\tscalar' "$tmp/schema"
    grep -Fxq $'SETUP_INPUT_SCRIPT\tscalar' "$tmp/schema"
    grep -Fxq $'HOST_COMMAND_POLICY\tscalar' "$tmp/schema"
    mkdir "$tmp/forward-project"
    printf '[hostname]\nallow\n' > "$tmp/forward-project/policy"
    (
        cd "$tmp/forward-project"
        JAILBOX_CONFIG_DEV_IMAGE=local/forwarding-test JAILBOX_CONFIG_HOST_COMMAND_POLICY=policy "$tmp/bin/jailbox" validate
    )
    mkdir "$tmp/setup-project"
    printf '#!/bin/sh\nexit 77\n' > "$tmp/setup-project/setup-home"
    cp "$tmp/setup-project/setup-home" "$tmp/setup-project/setup-input"
    chmod 755 "$tmp/setup-project/setup-home" "$tmp/setup-project/setup-input"
    (
        cd "$tmp/setup-project"
        "$tmp/bin/jailbox" init
        printf 'DEV_IMAGE=local/setup-test\nHOME_SETUP_SCRIPT=setup-home\nSETUP_INPUT_SCRIPT=setup-input\n' > jailbox.conf
        "$tmp/bin/jailbox" --config jailbox.conf validate
    )
    cmp "$tmp/jailbox-v9.9.9/README.md" "$tmp/share/jailbox/README.md"
    diff -r "$tmp/jailbox-v9.9.9/docs" "$tmp/share/jailbox/docs"
    cmp "$tmp/share/jailbox/VERSION" "$tmp/jailbox-v9.9.9/VERSION"

    # A mismatched helper cannot replace a working installation. Use the intact
    # dev build: editing a binary breaks its macOS code signature, and the OS
    # would kill it before it reports the mismatch. Rename a fresh copy into
    # place, because macOS can keep the signature of an overwritten file cached.
    cp -p src/libexec/jailbox-core "$tmp/jailbox-v9.9.9/libexec/jailbox-core.new"
    mv -f "$tmp/jailbox-v9.9.9/libexec/jailbox-core.new" "$tmp/jailbox-v9.9.9/libexec/jailbox-core"
    if JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" bash "$tmp/jailbox-v9.9.9/install.sh" > "$tmp/install-error" 2>&1; then return 1; fi
    grep -q 'jailbox helper version mismatch' "$tmp/install-error"
    [[ $("$tmp/bin/jailbox" --version) == 'jailbox 9.9.9' ]]

    JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./src/install.sh >/dev/null
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
    if JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./src/install.sh >"$tmp/out" 2>&1; then
        cat "$tmp/out"
        return 1
    fi
    grep -q "refusing to replace unmanaged install directory" "$tmp/out"
}

main() {
    section "syntax"
    bash "$SCRIPT_DIR/syntax.sh"
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
    if JAILBOX_INSTALL_DIR="$tmp/parent/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./src/install.sh > "$tmp/out" 2>&1; then return 1; fi
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
        if PATH="$tmp/tools:$PATH" PARTIAL="$partial" JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin" ./src/install.sh > "$tmp/out" 2>&1; then return 1; fi
        grep -q 'could not inspect install target' "$tmp/out"
        [[ $(cat "$tmp/share/jailbox/user-file") == keep && $(readlink "$tmp/bin/jailbox") == "$tmp/original" ]]
    done
}

main "$@"
