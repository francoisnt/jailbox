#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_die() { fail "$@"; }
cli() {
    [[ "$*" = 'exec -- cat' && "$LIFECYCLE_READONLY" = true ]] || fail 'observer did not invoke read-only exec'
    if [[ "$reply" = input ]]; then cat; else printf '%s' "$reply"; fi
    printf '%s' "$diagnostic" >&2
    return "$status"
}
reject() {
    if (observe_exec "$1" "$tmp/exec") > "$tmp/out" 2> "$tmp/err"; then fail 'observer accepted invalid exec'; fi
}
reply=input diagnostic='' status=0
observe_exec allow "$tmp/exec"
reply=truncated
reject allow
reply=input status=42
reject allow
reply='' diagnostic=failed
observe_exec refuse "$tmp/exec"
reply=executed
reject refuse
reply='' diagnostic=''
reject refuse
diagnostic='read-only observer attempted mutation'
reject refuse
printf 'PASS: exec observer checks input, status, refusal, and mutation\n'
