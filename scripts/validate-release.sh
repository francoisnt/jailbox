#!/bin/bash
# Validate locally built release assets before tagging or publication.
set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ "$#" -eq 2 ]] || die 'Usage: scripts/validate-release.sh VERSION DIST_DIR'
version=$1
[[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'invalid release version'
dist_dir=$(cd "$2" && pwd)
name="jailbox-$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cmp -s "$dist_dir/$name.tar.gz" "$dist_dir/jailbox-latest.tar.gz" || die 'latest archive differs from release archive'
for asset in "$name.tar.gz" jailbox-latest.tar.gz; do
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$dist_dir/$asset")
    else
        actual=$(shasum -a 256 "$dist_dir/$asset")
    fi
    expected=$(awk -v file="$asset" '$2 == file { print $1 }' "$dist_dir/SHA256SUMS")
    [[ "$expected" == "${actual%% *}" ]] || die "checksum mismatch for $asset"
done

# This validator consumes the artifact just built from trusted release source.
tar -xzf "$dist_dir/$name.tar.gz" -C "$tmp"
[[ -f "$tmp/$name/VERSION" && ! -L "$tmp/$name/VERSION" ]] || die 'release stamp is missing or invalid'
printf '%s\n' "${version#v}" > "$tmp/expected"
cmp -s "$tmp/expected" "$tmp/$name/VERSION" || die 'release stamp differs from selected version'
if ! bash "$tmp/$name/jailbox" --version > "$tmp/output" 2> "$tmp/error"; then
    die 'packaged --version failed'
fi
printf 'jailbox %s\n' "${version#v}" > "$tmp/expected"
if [[ -s "$tmp/error" ]] || ! cmp -s "$tmp/expected" "$tmp/output"; then
    die 'packaged --version differs from selected version'
fi
