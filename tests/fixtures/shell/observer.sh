#!/bin/bash
# Deliberately malformed public-command responses for the PTY observer oracle.
set -euo pipefail
[[ -t 0 && -t 1 ]] || exit 99
printf '%s' "$SHELL_TEST_OUTPUT"
printf '%s' "$SHELL_TEST_DIAGNOSTIC" >&2
exit "$SHELL_TEST_STATUS"
