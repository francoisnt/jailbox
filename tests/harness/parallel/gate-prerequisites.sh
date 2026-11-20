#!/bin/bash
# Every gate must reject missing Python before starting its suite-specific work.
# shellcheck disable=SC2329 # Stubs are invoked by the extracted prerequisite function.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck disable=SC1090
source <(sed -n '/^require_gate_prerequisites() {/,/^}/p' "$ROOT/tests/run")
declare -F require_gate_prerequisites >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for selected in dev lint portable runtime matrix editor; do
    status=0
    (
        die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
        gate_selected() { [[ "$1" = "$selected" ]]; }
        command() {
            [[ "$*" != '-v python3' ]] || return 1
            builtin command "$@"
        }
        require_gate_prerequisites
    ) > "$tmp/out" 2> "$tmp/err" || status=$?
    [[ "$status" = 1 && ! -s "$tmp/out" ]] || fail "$selected accepted missing Python"
    grep -Fxq 'Error: python3 is required for test gates' "$tmp/err" || fail "$selected missed early Python preflight"
done
for missing in shellcheck git; do
    if (
        die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
        gate_selected() { [[ "$1" = dev ]]; }
        command() {
            [[ "$*" != "-v $missing" ]] || return 1
            builtin command "$@"
        }
        require_gate_prerequisites
    ) > "$tmp/out" 2> "$tmp/err"; then fail "dev accepted missing $missing"; fi
    grep -Fq "$missing is required" "$tmp/err"
done
# The lint gate refuses to start without ShellCheck.
if (
    die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
    gate_selected() { [[ "$1" = lint ]]; }
    command() {
        [[ "$*" != '-v shellcheck' ]] || return 1
        builtin command "$@"
    }
    require_gate_prerequisites
) > "$tmp/out" 2> "$tmp/err"; then fail 'lint accepted missing shellcheck'; fi
grep -Fxq 'Error: shellcheck is required for the lint gate' "$tmp/err"
printf 'PASS: development checks and all five gates check Python before gate-specific prerequisites\n'
