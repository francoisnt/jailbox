#!/bin/bash
# Model container identity without consulting the portable test host's accounts.
set -euo pipefail
case "$*" in
    '-u jailbox'|'-g jailbox'|-u|-g) ;;
    *) printf 'Unexpected identity query: %s\n' "$*" >&2; exit 2 ;;
esac
case "${VALIDATION_ID_CASE:-healthy}:$*" in
    'missing-user:-u jailbox'|'missing-group:-g jailbox') exit 1 ;;
    root:*) printf '0\n' ;;
    'managed-mismatch:-g jailbox'|'wrong-uid:-u'|'wrong-gid:-g') printf '1501\n' ;;
    *) printf '1500\n' ;;
esac
