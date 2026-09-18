#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
observe() {
    python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$tmp" --output "$tmp/shell" \
        --expect "$1" -- bash "$ROOT/tests/fixtures/shell/observer.sh"
}
reject() {
    if observe "$1" > "$tmp/out" 2> "$tmp/err"; then fail 'PTY observer accepted an invalid response'; fi
}
export SHELL_TEST_OUTPUT=__jailbox_login_shell__ SHELL_TEST_DIAGNOSTIC='' SHELL_TEST_STATUS=0
observe allow
SHELL_TEST_STATUS=42
reject allow
SHELL_TEST_OUTPUT=truncated SHELL_TEST_STATUS=0
reject allow
SHELL_TEST_OUTPUT='' SHELL_TEST_DIAGNOSTIC=failed SHELL_TEST_STATUS=42
observe refuse
SHELL_TEST_OUTPUT=executed
reject refuse
SHELL_TEST_OUTPUT='' SHELL_TEST_DIAGNOSTIC=''
reject refuse
SHELL_TEST_DIAGNOSTIC='read-only observer attempted mutation'
reject refuse
SHELL_TEST_DIAGNOSTIC=failed SHELL_TEST_STATUS=0
reject refuse
printf 'PASS: shell observer enforces terminal attachment, status, refusal, and mutation evidence\n'
