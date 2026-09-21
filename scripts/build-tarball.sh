#!/bin/bash
set -euo pipefail

APP_NAME="jailbox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

RELEASE_PATHS=(install.sh README.md)

usage() {
    cat <<EOF_USAGE
Usage: scripts/build-tarball.sh VERSION

Build dist/jailbox-VERSION.tar.gz and dist/jailbox-latest.tar.gz from the current checkout.
VERSION must look like vMAJOR.MINOR.PATCH.
EOF_USAGE
}

# Print an error and stop packaging.
die() {
    echo "Error: $*" >&2
    exit 1
}

# sha256sum on Linux, shasum on macOS dev machines.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

version="${1:-}"
[ -n "$version" ] || { usage >&2; exit 2; }
[[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "invalid version '$version'"
[[ ! -e "$ROOT_DIR/VERSION" && ! -L "$ROOT_DIR/VERSION" &&
   ! -e "$ROOT_DIR/src/VERSION" && ! -L "$ROOT_DIR/src/VERSION" ]] || \
    die "refusing to package an existing VERSION stamp"

release_name="$APP_NAME-$version"
stage_dir="$DIST_DIR/$release_name"
tarball="$DIST_DIR/$release_name.tar.gz"
latest_tarball="$DIST_DIR/$APP_NAME-latest.tar.gz"
checksums_file="$DIST_DIR/SHA256SUMS"

for script in "$ROOT_DIR/install.sh" "$ROOT_DIR/src/jailbox" "$ROOT_DIR/src/public.sh"; do
    bash -n "$script" || die "invalid shell syntax: $script"
done
while IFS= read -r script; do
    bash -n "$script" || die "invalid shell syntax: $script"
done < <(find "$ROOT_DIR/src/host" "$ROOT_DIR/scripts" -type f -name '*.sh' -print)
source "$ROOT_DIR/scripts/lib/container-shells.sh"
check_container_syntax "$ROOT_DIR/src" || die 'invalid container shell source'

rm -rf "$stage_dir" "$tarball" "$latest_tarball" "$checksums_file"
mkdir -p "$stage_dir"
cp -R "$ROOT_DIR/src/." "$stage_dir/"

for path in "${RELEASE_PATHS[@]}"; do
    [ -e "$ROOT_DIR/$path" ] || die "missing release path: $path"
    cp -R "$ROOT_DIR/$path" "$stage_dir/"
done

printf '%s\n' "${version#v}" > "$stage_dir/VERSION"

# Ensure entry-point scripts remain executable after copying into the stage dir.
chmod 755 "$stage_dir/jailbox" "$stage_dir/install.sh"
chmod 755 "$stage_dir"/container/*.sh

# Build from inside dist so the archive has a clean top-level directory.
(cd "$DIST_DIR" && tar -czf "$release_name.tar.gz" "$release_name")
cp "$tarball" "$latest_tarball"
rm -rf "$stage_dir"

# Checksums use bare filenames so `sha256sum --check` works from the
# download directory.
(cd "$DIST_DIR" && sha256 "$release_name.tar.gz" "$APP_NAME-latest.tar.gz" > SHA256SUMS)

bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$DIST_DIR"

echo "$tarball"
