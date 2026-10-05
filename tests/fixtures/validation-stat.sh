#!/bin/bash
# Model Linux device numbers independently of the portable test host's devices.
set -euo pipefail
if [[ "$#" != 4 || "$1" != -Lc || "$2" != '%t:%T' || "$3" != -- ]]; then
    printf 'Unexpected device query: %s\n' "$*" >&2
    exit 2
fi
case "$4" in
    /dev/null) printf '1:3\n' ;;
    /dev/zero) printf '1:5\n' ;;
    *) printf 'Unexpected device path: %s\n' "$4" >&2; exit 2 ;;
esac
