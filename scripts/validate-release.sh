#!/bin/bash
# Validate locally built release assets before tagging or publication.
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ "$#" -eq 2 ]] || die 'Usage: scripts/validate-release.sh VERSION DIST_DIR'
version=$1
[[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'invalid release version'
dist_dir=$(cd "$2" && pwd -P)
name="jailbox-$version"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export GOTOOLCHAIN=local

verify_checksum() {
    local asset=$1 actual expected
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$dist_dir/$asset")
    else
        actual=$(shasum -a 256 "$dist_dir/$asset")
    fi
    expected=$(awk -v file="$asset" '$2 == file { print $1 }' "$dist_dir/SHA256SUMS")
    [[ "$expected" == "${actual%% *}" ]] || die "checksum mismatch for $asset"
}

verify_program() {
    local binary=$1 platform=$2 info
    [[ -x "$binary" ]] || die "missing packaged program for $platform"
    info=$(go version -m "$binary") || die "could not inspect packaged program for $platform"
    for setting in "GOOS=${platform%-*}" "GOARCH=${platform#*-}" CGO_ENABLED=0; do
        [[ "$info" = *$'\t'"$setting"$'\n'* || "$info" = *$'\t'"$setting" ]] ||
            die "packaged program has invalid build settings for $platform"
    done
    # Trimmed build info omits the linker version stamp. Match its delimited marker.
    LC_ALL=C grep -aqF "jailbox-build-version:${version#v}:" "$binary" ||
        die "packaged program for $platform is not stamped with ${version#v}"
}

verify_checksum install.sh
bash -n "$dist_dir/install.sh" || die 'release installer has invalid syntax'
[[ $(grep '^RELEASE_VERSION=' "$dist_dir/install.sh") == "RELEASE_VERSION=\"$version\"" ]] ||
    die 'release installer pin differs from selected version'

for platform in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
    archive="$name-$platform.tar.gz"
    latest="jailbox-latest-$platform.tar.gz"
    verify_checksum "$archive"
    verify_checksum "$latest"
    cmp -s "$dist_dir/$archive" "$dist_dir/$latest" || die "latest archive differs from release archive for $platform"

    tar -xzf "$dist_dir/$archive" -C "$tmp"
    tree="$tmp/$name"
    cmp -s "$dist_dir/install.sh" "$tree/install.sh" || die 'release installers differ'
    [[ -f "$tree/VERSION" && ! -L "$tree/VERSION" ]] || die 'release stamp is missing or invalid'
    cmp -s "$tree/VERSION" <(printf '%s\n' "${version#v}") || die 'release stamp differs from selected version'
    if ! bash "$tree/jailbox" --version > "$tmp/output" 2> "$tmp/error"; then
        die 'packaged --version failed'
    fi
    if [[ -s "$tmp/error" ]] || ! cmp -s "$tmp/output" <(printf 'jailbox %s\n' "${version#v}"); then
        die 'packaged --version differs from selected version'
    fi
    verify_program "$tree/libexec/jailbox-core" "$platform"
    for arch in amd64 arm64; do
        verify_program "$tree/libexec/linux-$arch/jailbox-container" "linux-$arch"
    done
    rm -rf -- "$tree"
done
