#!/bin/bash
set -euo pipefail

APP_NAME="jailbox"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

RELEASE_PATHS=(README.md LICENSE docs)

usage() {
    cat <<EOF_USAGE
Usage: scripts/build-tarball.sh VERSION

Build release archives, dist/install.sh, and checksums from the current checkout.
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
platforms=(linux-amd64 linux-arm64 darwin-amd64 darwin-arm64)

for script in "$ROOT_DIR/src/install.sh" "$ROOT_DIR/src/jailbox" "$ROOT_DIR/src/public-api.sh"; do
    bash -n "$script" || die "invalid shell syntax: $script"
done
while IFS= read -r script; do
    bash -n "$script" || die "invalid shell syntax: $script"
done < <(find "$ROOT_DIR/src/host" "$ROOT_DIR/scripts" -type f -name '*.sh' -print)
source "$ROOT_DIR/scripts/lib/container-shells.sh"
check_container_syntax "$ROOT_DIR/src" || die 'invalid container shell source'

mkdir -p "$DIST_DIR"
stage=$(mktemp -d "$DIST_DIR/.build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
stage_dir="$stage/$release_name"
mkdir "$stage_dir"
# Preserve automatic runtime discovery and omit build-only Go packages.
cp -R "$ROOT_DIR/src/." "$stage_dir/"
rm -rf -- "$stage_dir/go.mod" "$stage_dir/go.sum" "$stage_dir/internal" "$stage_dir/libexec" \
    "$stage_dir/container/cmd" "$stage_dir/container/internal" \
    "$stage_dir/host/core/cmd" "$stage_dir/host/core/internal"

for path in "${RELEASE_PATHS[@]}"; do
    [ -e "$ROOT_DIR/$path" ] || die "missing release path: $path"
    cp -R "$ROOT_DIR/$path" "$stage_dir/"
done

printf '%s\n' "${version#v}" > "$stage_dir/VERSION"
sed "s/^RELEASE_VERSION=\"\"$/RELEASE_VERSION=\"$version\"/" \
    "$ROOT_DIR/src/install.sh" > "$stage_dir/install.sh"
chmod 755 "$stage_dir/jailbox" "$stage_dir/install.sh" "$stage_dir"/container/*.sh
cp "$stage_dir/install.sh" "$stage/install.sh"

# Build every program once, then give each archive its own core program.
programs="$stage/programs"
bash "$ROOT_DIR/scripts/build-programs.sh" --release "$programs" "${version#v}"
assets=()
for platform in "${platforms[@]}"; do
    rm -rf -- "$stage_dir/libexec"
    mkdir -p "$stage_dir/libexec/linux-amd64" "$stage_dir/libexec/linux-arm64"
    cp -p -- "$programs/core/$platform/jailbox-core" "$stage_dir/libexec/jailbox-core"
    for arch in amd64 arm64; do
        cp -p -- "$programs/linux-$arch/jailbox-container" "$stage_dir/libexec/linux-$arch/jailbox-container"
    done
    asset="$release_name-$platform.tar.gz"
    latest="$APP_NAME-latest-$platform.tar.gz"
    (cd "$stage" && tar -czf "$asset" "$release_name")
    cp "$stage/$asset" "$stage/$latest"
    assets+=("$asset" "$latest")
done
(cd "$stage" && sha256 "${assets[@]}" install.sh > SHA256SUMS)
bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$stage"
for asset in "${assets[@]}" install.sh SHA256SUMS; do
    mv -f -- "$stage/$asset" "$DIST_DIR/$asset"
done
printf 'dist/%s\n' "${assets[@]}"
