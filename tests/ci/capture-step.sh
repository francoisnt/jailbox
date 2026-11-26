#!/bin/bash
# Retain setup diagnostics in the gate's existing always-uploaded artifact.
# With no command arguments, execute the workflow's Bash program on stdin.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
if (($# < 2)); then
    echo 'Usage: capture-step.sh GATE STEP [COMMAND...]' >&2
    exit 2
fi
gate=$1 step=$2
shift 2
case "$gate" in lint|portable|runtime|matrix|editor) ;; *) exit 2 ;; esac
[[ "$step" =~ ^[a-z0-9-]+$ ]] || exit 2
log_dir="$ROOT_DIR/testlog/ci-setup/$gate"
mkdir -p "$log_dir"
if (($# == 0)); then set -- bash -euo pipefail -s; fi

# The portable setup can run before modern Bash is installed on macOS.
if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
    # shellcheck source=tests/lib/logging.sh
    source "$ROOT_DIR/tests/lib/logging.sh"
    "$@" 2>&1 | test_timestamp_stream | tee "$log_dir/$step.log"
else
    "$@" 2>&1 | tee "$log_dir/$step.log"
fi
