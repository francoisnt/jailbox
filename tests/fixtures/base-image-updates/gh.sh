#!/bin/bash
# Keep canary issue titles, open or closed, one per line in $GH_ISSUES.
# Append each new issue body to $GH_BODIES. GH_LIST_FAIL makes the issue
# lookup fail.
set -euo pipefail

case "$1 $2" in
    'label create') ;;
    'issue list')
        [[ -z "${GH_LIST_FAIL:-}" ]] || exit 94
        cat "${GH_ISSUES:?}"
        ;;
    'issue create')
        title=''
        body=''
        shift 2
        while (($#)); do
            case "$1" in
                --title) title=$2; shift ;;
                --body) body=$2; shift ;;
            esac
            shift
        done
        [[ -n "$title" && -n "$body" ]] || exit 92
        printf '%s\n' "$title" >> "$GH_ISSUES"
        printf '%s\n' "$body" >> "${GH_BODIES:?}"
        ;;
    *) exit 93 ;;
esac
