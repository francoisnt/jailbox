#!/bin/bash
# Serve Docker Official Images tag lists. MANIFESTS=current reports the
# fixture's pinned releases as stable; ALPINE_MANIFEST selects Alpine cases.
set -euo pipefail

current=${MANIFESTS:-new}
case "${!#}" in
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
