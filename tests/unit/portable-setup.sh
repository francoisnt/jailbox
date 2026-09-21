#!/bin/bash
# macOS setup must install and select GNU find, not the system BSD find.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/ci/setup-portable.sh
source "$ROOT/tests/ci/setup-portable.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
real_find=$(command -v find)
mkdir -p "$tmp/findutils/libexec/gnubin"
ln -s "$real_find" "$tmp/findutils/libexec/gnubin/find"
GITHUB_PATH="$tmp/github-path"
uname() { printf 'Darwin\n'; }
brew() {
    case "$1" in
        install) printf '%s\n' "${@:2}" > "$tmp/packages" ;;
        --prefix) printf '%s/%s\n' "$tmp" "$2" ;;
        *) return 1 ;;
    esac
}
install_portable_tools > "$tmp/output"
grep -Fxq findutils "$tmp/packages"
grep -Fxq "$tmp/findutils/libexec/gnubin" "$GITHUB_PATH"
[[ $(command -v find) = "$tmp/findutils/libexec/gnubin/find" ]]
[[ $(find "$tmp" -maxdepth 0 -printf '%f') = "${tmp##*/}" ]]
printf 'PASS: macOS setup installs and selects GNU findutils\n'
