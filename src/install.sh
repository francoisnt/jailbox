#!/bin/bash
set -euo pipefail

APP_NAME="jailbox"
MARKER_FILE=".jailbox-install"
if [ "${#BASH_SOURCE[@]}" -gt 0 ]; then
    SOURCE_FILE="${BASH_SOURCE[0]}"
else
    SOURCE_FILE=""
fi
if [ -n "$SOURCE_FILE" ]; then
    SOURCE_DIR="$(cd "$(dirname "$SOURCE_FILE")" && pwd)"
else
    SOURCE_DIR="$(pwd)"
fi
# Packaging stamps the published installer; unstamped source streams use latest.
RELEASE_VERSION=""
if [ -n "$RELEASE_VERSION" ]; then
    RELEASE_BASE_URL="https://github.com/francoisnt/jailbox/releases/download/$RELEASE_VERSION"
else
    RELEASE_BASE_URL="https://github.com/francoisnt/jailbox/releases/latest/download"
fi
RELEASE_BASE_URL="${JAILBOX_RELEASE_BASE_URL:-$RELEASE_BASE_URL}"
RELEASE_TMP_DIR=""

if [ -n "${JAILBOX_INSTALL_DIR:-}" ]; then
    TARGET_DIR="$JAILBOX_INSTALL_DIR"
elif [ -n "${PREFIX:-}" ]; then
    TARGET_DIR="$PREFIX/share/$APP_NAME"
else
    TARGET_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_NAME"
fi

if [ -n "${JAILBOX_BIN_DIR:-}" ]; then
    BIN_DIR="$JAILBOX_BIN_DIR"
elif [ -n "${PREFIX:-}" ]; then
    BIN_DIR="$PREFIX/bin"
else
    BIN_DIR="$HOME/.local/bin"
fi

LINK_PATH="$BIN_DIR/$APP_NAME"

usage() {
    cat <<EOF_USAGE
Usage: ./install.sh [--uninstall|--help]

Installs jailbox to:
  $TARGET_DIR
  $LINK_PATH

Environment overrides:
  PREFIX                 Install under PREFIX/share and PREFIX/bin
  XDG_DATA_HOME          Default data parent when PREFIX is unset
  JAILBOX_INSTALL_DIR    Exact app asset directory
  JAILBOX_BIN_DIR        Exact directory for the jailbox symlink
  JAILBOX_RELEASE_BASE_URL
                         Release asset base URL for streamed installs
EOF_USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        die "sha256sum or shasum is required"
    fi
}

download_file() {
    local url output

    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
    else
        die "curl or wget is required"
    fi
}

installer_bundle_is_available() {
    # A piped installer must download its release, regardless of the working directory.
    [ -n "$SOURCE_FILE" ] || return 1
    # The unstamped checkout copy always installs the files beside it.
    [ -n "$RELEASE_VERSION" ] || return 0
    # A published installer installs the files beside it only inside its own
    # release. Saved anywhere else, for example in a project with its own
    # VERSION file or container/ directory, it downloads its release.
    [ -f "$SOURCE_DIR/jailbox" ] && [ -f "$SOURCE_DIR/VERSION" ] || return 1
    [ "$(cat "$SOURCE_DIR/VERSION")" = "${RELEASE_VERSION#v}" ]
}

absolute_path() {
    local path parent base

    path="$1"
    parent="$(dirname "$path")" || return 1
    base="$(basename "$path")" || return 1
    mkdir -p "$parent" || return 1
    parent="$(cd "$parent" && pwd -P)" || return 1
    printf '%s/%s\n' "$parent" "$base"
}

assert_safe_target_dir() {
    local abs_target abs_home

    abs_target="$(absolute_path "$TARGET_DIR")" || die "could not resolve install target"
    abs_home="$(cd "$HOME" && pwd -P)" || die "could not resolve HOME"

    [ -n "$abs_target" ] || die "install target is empty"
    [ "$abs_target" != "/" ] || die "refusing to install to /"
    [ "$abs_target" != "$abs_home" ] || die "refusing to install directly to HOME"
    [ "$(basename "$abs_target")" = "$APP_NAME" ] || \
        die "install target must end in /$APP_NAME: $TARGET_DIR"

    TARGET_DIR="$abs_target"
    LINK_PATH="$BIN_DIR/$APP_NAME"
}

assert_managed_target_dir() {
    if [ ! -f "$TARGET_DIR/$MARKER_FILE" ]; then
        die "refusing to remove unmanaged install directory: $TARGET_DIR"
    fi
}

assert_replaceable_target_dir() {
    local contents
    if [ -f "$TARGET_DIR/$MARKER_FILE" ]; then
        return 0
    fi

    contents=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit) || die "could not inspect install target: $TARGET_DIR"
    if [ -z "$contents" ]; then
        return 0
    fi

    die "refusing to replace unmanaged install directory: $TARGET_DIR"
}

# Check bundle shape; recursive copying owns the runtime file inventory.
validate_source_tree() {
    local path
    for path in jailbox install.sh public-api.sh host/prerequisites.sh; do
        [ -f "$SOURCE_DIR/$path" ] || die "installer bundle is missing required file: $path"
    done
    for path in host container; do
        [ -d "$SOURCE_DIR/$path" ] || die "installer bundle is missing required directory: $path"
    done
}

release_platform() {
    local system machine
    system=$(uname -s) || return 1
    machine=$(uname -m) || return 1
    case "$system" in Linux) system=linux ;; Darwin) system=darwin ;; *) die "unsupported host OS: $system" ;; esac
    case "$machine" in
        x86_64|amd64) machine=amd64 ;;
        aarch64|arm64) machine=arm64 ;;
        *) die "unsupported host architecture: $machine" ;;
    esac
    printf '%s-%s\n' "$system" "$machine"
}

validate_programs() {
    local path version=dev
    for path in libexec/jailbox-core libexec/linux-amd64/jailbox-container libexec/linux-arm64/jailbox-container; do
        [ -f "$SOURCE_DIR/$path" ] && [ -x "$SOURCE_DIR/$path" ] ||
            die "missing jailbox program $path. Build checkout programs with scripts/build-programs.sh or reinstall from a release."
    done
    if [ -f "$SOURCE_DIR/VERSION" ]; then
        version=$(cat "$SOURCE_DIR/VERSION") || die "could not read the jailbox version"
    fi
    "$SOURCE_DIR/libexec/jailbox-core" "$version" version ||
        die "incompatible jailbox program. Build checkout programs or download the release for your platform."
}

install_from_release() {
    local tmp_dir tarball checksums tar_list expected actual release_dir platform asset

    platform=$(release_platform) || exit 1
    asset="$APP_NAME-latest-$platform.tar.gz"

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.install.XXXXXX")"
    RELEASE_TMP_DIR="$tmp_dir"
    cleanup_release_download() {
        [ -n "${RELEASE_TMP_DIR:-}" ] && rm -rf "$RELEASE_TMP_DIR"
    }
    trap cleanup_release_download EXIT

    tarball="$tmp_dir/$asset"
    checksums="$tmp_dir/SHA256SUMS"
    tar_list="$tmp_dir/tar.list"

    echo "Downloading jailbox..."
    download_file "$RELEASE_BASE_URL/$asset" "$tarball"
    download_file "$RELEASE_BASE_URL/SHA256SUMS" "$checksums"

    expected="$(awk -v file="$asset" '$2 == file { print $1; exit }' "$checksums")"
    [ -n "$expected" ] || die "checksum file does not include $asset"
    actual="$(sha256 "$tarball" | awk '{ print $1 }')"
    [ "$actual" = "$expected" ] || die "checksum verification failed for $asset"

    tar -tzf "$tarball" > "$tar_list"
    release_dir="$(sed -n '1{s#/.*##;p;q;}' "$tar_list")"
    [ -n "$release_dir" ] || die "release archive is empty"
    tar -xzf "$tarball" -C "$tmp_dir"
    [ -f "$tmp_dir/$release_dir/install.sh" ] || die "release archive is missing install.sh"

    bash "$tmp_dir/$release_dir/install.sh" "$@"
    trap - EXIT
    rm -rf "$tmp_dir"
    RELEASE_TMP_DIR=""
}

copy_bundle() {
    local tmp_dir script document

    tmp_dir="$1"
    cp -R "$SOURCE_DIR/." "$tmp_dir/" || die "could not copy installer bundle"
    # Checkout-only build inputs are never part of an installed runtime.
    rm -rf -- "$tmp_dir/go.mod" "$tmp_dir/go.sum" "$tmp_dir/internal" \
        "$tmp_dir/container/cmd" "$tmp_dir/container/internal" \
        "$tmp_dir/host/core/cmd" "$tmp_dir/host/core/internal" "$tmp_dir/libexec/native"
    # Release bundles include these documents; checkouts keep them above src/.
    for document in README.md LICENSE; do
        if [ ! -f "$tmp_dir/$document" ]; then
            cp "$SOURCE_DIR/../$document" "$tmp_dir/$document" || die "could not copy $document"
        fi
    done

    if [ ! -d "$tmp_dir/docs" ]; then
        cp -R "$SOURCE_DIR/../docs" "$tmp_dir/docs" || die "could not copy docs"
    fi

    chmod 755 "$tmp_dir/jailbox"
    for script in "$tmp_dir"/container/*.sh; do
        [ -f "$script" ] || continue
        chmod 755 "$script"
    done
    [ -f "$tmp_dir/install.sh" ] && chmod 755 "$tmp_dir/install.sh"
    printf '%s\n' "$APP_NAME" > "$tmp_dir/$MARKER_FILE"
}

rollback_install() {
    local status=$?
    if [ "$published" = true ] && ! mv "$TARGET_DIR" "$stage/new"; then
        printf 'Error: could not move the replacement aside during rollback. Update files are in %s\n' "$stage" >&2
    elif [ -d "$stage/previous" ] && ! mv "$stage/previous" "$TARGET_DIR"; then
        printf 'Error: could not restore the previous installation from %s\n' "$stage/previous" >&2
    elif ! rm -rf "$stage"; then
        printf 'Error: could not remove temporary update files at %s\n' "$stage" >&2
    fi
    exit "$status"
}

install_jailbox() (
    local parent_dir stage published=false

    validate_source_tree
    validate_programs
    # Streamed installs reach this check in the downloaded bundle's installer.
    # Recovery/help remain available even when runtime utilities are missing.
    # shellcheck source=src/host/prerequisites.sh
    source "$SOURCE_DIR/host/prerequisites.sh"
    require_host_realpath || exit 1
    require_host_sort || exit 1
    assert_safe_target_dir

    mkdir -p "$BIN_DIR"
    parent_dir="$(dirname "$TARGET_DIR")"
    mkdir -p "$parent_dir"

    stage="$(mktemp -d "$parent_dir/.${APP_NAME}.install.XXXXXX")" || die "could not stage installation"
    trap rollback_install EXIT

    mkdir -m 700 "$stage/new" || die "could not prepare replacement directory"
    copy_bundle "$stage/new"

    if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
        die "$LINK_PATH already exists and is not a symlink"
    fi

    if [ -L "$TARGET_DIR" ]; then
        die "$TARGET_DIR already exists and is a symlink"
    fi

    if [ -e "$TARGET_DIR" ] && [ ! -d "$TARGET_DIR" ]; then
        die "$TARGET_DIR already exists and is not a directory"
    fi

    if [ -d "$TARGET_DIR" ]; then
        assert_replaceable_target_dir
        mv "$TARGET_DIR" "$stage/previous" || die "could not move the previous installation aside"
    fi

    mv "$stage/new" "$TARGET_DIR" || die "could not publish the installation"
    published=true
    if [ ! -L "$LINK_PATH" ] || [ "$(readlink "$LINK_PATH")" != "$TARGET_DIR/jailbox" ]; then
        ln -sfn "$TARGET_DIR/jailbox" "$LINK_PATH" || die "could not publish the jailbox command at $LINK_PATH"
    fi

    trap - EXIT
    rm -rf "$stage" || die "jailbox was installed, but could not remove update files at $stage"

    echo "jailbox installed to $LINK_PATH"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "Note: $BIN_DIR is not in PATH." ;;
    esac
)

uninstall_jailbox() {
    assert_safe_target_dir

    if [ -L "$LINK_PATH" ] && [ "$(readlink "$LINK_PATH")" = "$TARGET_DIR/jailbox" ]; then
        rm -f "$LINK_PATH"
    fi

    if [ -d "$TARGET_DIR" ]; then
        assert_managed_target_dir
        rm -rf "$TARGET_DIR"
    fi

    echo "jailbox uninstalled from $TARGET_DIR"
}

case "${1:-}" in
    "")
        if installer_bundle_is_available; then
            install_jailbox
        else
            install_from_release "$@"
        fi
        ;;
    --uninstall)
        uninstall_jailbox
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
