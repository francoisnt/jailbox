#!/bin/bash
# Serve upstream version lookups for the dependency-update tests.
# MANIFESTS=current reports the fixture pins as the stable images;
# ALPINE_MANIFEST selects Alpine cases; FAIL_URL fails requests containing it;
# GO_LISTING_FIXTURE and GO_LOOKUP_LOG serve and count Go listing requests;
# CODIUM_ARCHIVE names the archive served for VSCodium downloads (written to -o).
set -euo pipefail

url=''
output=''
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == -o ]]; then output=${args[i + 1]}; fi
done
for arg in "$@"; do
    case "$arg" in https://*) url=$arg ;; esac
done
if [[ -n "${FAIL_URL:-}" && "$url" == *"$FAIL_URL"* ]]; then
    echo 'curl: (22) The requested URL returned error: 503' >&2
    exit 22
fi

current=${MANIFESTS:-new}
case "$url" in
    https://go.dev/dl/*)
        printf '%s\n' "$url" >> "${GO_LOOKUP_LOG:?}"
        cat -- "${GO_LISTING_FIXTURE:?}"
        ;;
    https://api.github.com/repos/VSCodium/*) printf '%s\n' '{"tag_name":"1.0.2"}' ;;
    https://update.code.visualstudio.com/*) printf '%s\n' '{"productVersion":"1.1.0"}' ;;
    https://marketplace.visualstudio.com/*) printf '%s\n' '{"results":[{"extensions":[{"versions":[{"version":"0.1.0"}]}]}]}' ;;
    https://open-vsx.org/*) printf '%s\n' '{"version":"0.2.0"}' ;;
    https://github.com/VSCodium/vscodium/releases/download/*)
        cp -- "${CODIUM_ARCHIVE:?}" "${output:?}"
        ;;
    */library/alpine)
        case ${ALPINE_MANIFEST:-$current} in
            new) printf '%s\n' 'Tags: 20261121, edge' 'Tags: 3.25.2, 3.25, 3, latest' ;;
            current) printf '%s\n' 'Tags: 3.24.4, 3.24, 3, latest' ;;
            older) printf '%s\n' 'Tags: 3.23.8, 3.23, 3, latest' ;;
            ambiguous) printf '%s\n' 'Tags: 3.25, 3.26, latest' ;;
            *) exit 90 ;;
        esac
        ;;
    */library/debian)
        case $current in
            new) printf '%s\n' 'Tags: forky, testing' 'Tags: trixie, 13.8, 13, latest' ;;
            current) printf '%s\n' 'Tags: bookworm, 12.12, 12, latest' ;;
        esac
        ;;
    */library/fedora)
        case $current in
            new) printf '%s\n' 'Tags: 46, rawhide' 'Tags: 45, latest' ;;
            current) printf '%s\n' 'Tags: 42, rawhide' 'Tags: 41, latest' ;;
        esac
        ;;
    *) exit 91 ;;
esac
