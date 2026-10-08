#!/bin/bash
# Serve distinct latest and pinned releases; reject unexpected download paths.
set -euo pipefail
[[ $# == 4 && $1 == -fsSL && $3 == -o ]]
printf '%s\n' "$2" >> "$INSTALLER_REQUESTS"
case "$2" in
    https://github.com/francoisnt/jailbox/releases/latest/download/*)
        assets=$INSTALLER_ASSETS ;;
    https://github.com/francoisnt/jailbox/releases/download/v9.8.7/*)
        assets=$INSTALLER_PINNED_ASSETS ;;
    *) printf 'Unexpected installer request\n' >&2; exit 1 ;;
esac
case "${2##*/}" in
    jailbox-latest.tar.gz|SHA256SUMS) cp "$assets/${2##*/}" "$4" ;;
    *) printf 'Unexpected installer asset\n' >&2; exit 1 ;;
esac
