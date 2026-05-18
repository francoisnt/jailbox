#!/bin/bash
set -euo pipefail

APP_NAME="jailbox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

RELEASE_PATHS=(
    "jailbox"
    "install.sh"
    "README.md"
    "scripts"
    "lib"
    "install"
    "Containerfile.proxy"
    "Containerfile.wrapper"
    "tinyproxy.conf"
)

usage() {
    cat <<EOF_USAGE
Usage: scripts/build-tarball.sh VERSION

Build dist/jailbox-VERSION.tar.gz from the current checkout.
VERSION must look like vMAJOR.MINOR.PATCH.
EOF_USAGE
}

# Print an error and stop packaging.
die() {
    echo "Error: $*" >&2
    exit 1
}

version="${1:-}"
[ -n "$version" ] || { usage >&2; exit 2; }
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$version'"

release_name="$APP_NAME-$version"
stage_dir="$DIST_DIR/$release_name"
tarball="$DIST_DIR/$release_name.tar.gz"

bash -n "$ROOT_DIR/install.sh" "$ROOT_DIR/jailbox" "$ROOT_DIR"/lib/*.sh "$ROOT_DIR"/scripts/*.sh
sh -n "$ROOT_DIR"/install/*.sh

rm -rf "$stage_dir" "$tarball"
mkdir -p "$stage_dir"

for path in "${RELEASE_PATHS[@]}"; do
    [ -e "$ROOT_DIR/$path" ] || die "missing release path: $path"
    cp -R "$ROOT_DIR/$path" "$stage_dir/"
done

# Ensure entry-point scripts remain executable after copying into the stage dir.
chmod 755 "$stage_dir/jailbox" "$stage_dir/install.sh"
chmod 755 "$stage_dir"/install/*.sh

# Build from inside dist so the archive has a clean top-level directory.
(cd "$DIST_DIR" && tar -czf "$release_name.tar.gz" "$release_name")
rm -rf "$stage_dir"

echo "$tarball"
