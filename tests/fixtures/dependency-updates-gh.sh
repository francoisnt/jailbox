#!/bin/bash
# Record issue creation for the dependency-update tests: each created issue
# appends its title and body to $GH_LOG. GH_FAIL makes creation fail.
set -euo pipefail

case "$1 $2" in
    'label create') ;;
    'issue create')
        [[ -z "${GH_FAIL:-}" ]] || exit 94
        shift 2
        while (($#)); do
            case "$1" in
                --title) printf 'TITLE %s\n' "$2" >> "${GH_LOG:?}"; shift ;;
                --body) printf 'BODY %s\n' "$2" >> "$GH_LOG"; shift ;;
            esac
            shift
        done
        ;;
    *) exit 93 ;;
esac
