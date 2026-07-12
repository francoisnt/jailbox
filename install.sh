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
RELEASE_BASE_URL="${JAILBOX_RELEASE_BASE_URL:-https://github.com/francoisnt/jailbox/releases/latest/download}"
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

REQUIRED_PATHS=(
    "jailbox"
    "host/common.sh"
    "host/dev-image.sh"
    "host/downloader-proxy.sh"
    "host/editor.sh"
    "host/network.sh"
    "host/preflight.sh"
    "host/project-id.sh"
    "host/public-api.sh"
    "host/container-runtime.sh"
    "host/ssh.sh"
    "host/validation.sh"
    "container/setup.sh"
    "container/downloader-proxy-manager.sh"
    "container/entrypoint.sh"
    "container/tinyproxy/Containerfile"
    "container/Containerfile.wrapper"
    "container/tinyproxy/tinyproxy.conf"
)

INSTALL_PATHS=(
    "jailbox"
    "host"
    "container"
    "README.md"
    "install.sh"
)

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
    local path

    for path in "${REQUIRED_PATHS[@]}"; do
        [ -e "$SOURCE_DIR/$path" ] || return 1
    done
}

absolute_path() {
    local path parent base

    path="$1"
    parent="$(dirname "$path")"
    base="$(basename "$path")"
    mkdir -p "$parent"
    parent="$(cd "$parent" && pwd -P)"
    printf '%s/%s\n' "$parent" "$base"
}

assert_safe_target_dir() {
    local abs_target abs_home

    abs_target="$(absolute_path "$TARGET_DIR")"
    abs_home="$(cd "$HOME" && pwd -P)"

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
    if [ -f "$TARGET_DIR/$MARKER_FILE" ]; then
        return 0
    fi

    if [ -z "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        return 0
    fi

    die "refusing to replace unmanaged install directory: $TARGET_DIR"
}

validate_source_tree() {
    local path

    for path in "${REQUIRED_PATHS[@]}"; do
        [ -e "$SOURCE_DIR/$path" ] || die "installer bundle is missing required path: $path"
    done
}

install_from_release() {
    local tmp_dir tarball checksums tar_list expected actual release_dir

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.install.XXXXXX")"
    RELEASE_TMP_DIR="$tmp_dir"
    cleanup_release_download() {
        [ -n "${RELEASE_TMP_DIR:-}" ] && rm -rf "$RELEASE_TMP_DIR"
    }
    trap cleanup_release_download EXIT

    tarball="$tmp_dir/$APP_NAME-latest.tar.gz"
    checksums="$tmp_dir/SHA256SUMS"
    tar_list="$tmp_dir/tar.list"

    echo "Downloading jailbox..."
    download_file "$RELEASE_BASE_URL/$APP_NAME-latest.tar.gz" "$tarball"
    download_file "$RELEASE_BASE_URL/SHA256SUMS" "$checksums"

    expected="$(awk -v file="$APP_NAME-latest.tar.gz" '$2 == file { print $1; exit }' "$checksums")"
    [ -n "$expected" ] || die "checksum file does not include $APP_NAME-latest.tar.gz"
    actual="$(sha256 "$tarball" | awk '{ print $1 }')"
    [ "$actual" = "$expected" ] || die "checksum verification failed for $APP_NAME-latest.tar.gz"

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
    local tmp_dir path script

    tmp_dir="$1"
    for path in "${INSTALL_PATHS[@]}"; do
        [ -e "$SOURCE_DIR/$path" ] && cp -R "$SOURCE_DIR/$path" "$tmp_dir/"
    done

    chmod 755 "$tmp_dir/jailbox"
    for script in "$tmp_dir"/container/*.sh; do
        [ -f "$script" ] || continue
        chmod 755 "$script"
    done
    [ -f "$tmp_dir/install.sh" ] && chmod 755 "$tmp_dir/install.sh"
    printf '%s\n' "$APP_NAME" > "$tmp_dir/$MARKER_FILE"
}

install_jailbox() {
    local parent_dir tmp_dir backup_dir

    validate_source_tree
    assert_safe_target_dir

    mkdir -p "$BIN_DIR"
    parent_dir="$(dirname "$TARGET_DIR")"
    mkdir -p "$parent_dir"

    tmp_dir="$(mktemp -d "$parent_dir/.${APP_NAME}.install.XXXXXX")"
    backup_dir=""

    cleanup() {
        [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ] && rm -rf "$tmp_dir"
        if [ -n "$backup_dir" ] && [ -d "$backup_dir" ] && [ ! -d "$TARGET_DIR" ]; then
            mv "$backup_dir" "$TARGET_DIR"
        fi
    }
    trap cleanup EXIT

    copy_bundle "$tmp_dir"

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
        backup_dir="$(mktemp -d "$parent_dir/.${APP_NAME}.backup.XXXXXX")"
        rmdir "$backup_dir"
        mv "$TARGET_DIR" "$backup_dir"
    fi

    mv "$tmp_dir" "$TARGET_DIR"
    tmp_dir=""
    ln -sfn "$TARGET_DIR/jailbox" "$LINK_PATH"

    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
        rm -rf "$backup_dir"
        backup_dir=""
    fi

    trap - EXIT

    echo "jailbox installed to $LINK_PATH"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "Note: $BIN_DIR is not in PATH." ;;
    esac
}

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
