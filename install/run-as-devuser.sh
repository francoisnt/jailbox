#!/bin/sh
# Portable helper: run a shell command as devuser.
# Usage:
#   sh run-as-devuser.sh '<shell command>'
#   printf '%s\n' '<shell script>' | sh run-as-devuser.sh
set -e

COMMAND="${1:-}"

if [ -n "$COMMAND" ]; then
    if command -v runuser >/dev/null 2>&1; then
        runuser -u devuser -- sh -lc "$COMMAND"
    elif command -v su >/dev/null 2>&1; then
        su devuser -c "$COMMAND"
    elif command -v busybox >/dev/null 2>&1 && busybox su --help >/dev/null 2>&1; then
        busybox su devuser -c "$COMMAND"
    else
        echo "Error: cannot run as devuser — no runuser, su, or busybox su found" >&2
        exit 1
    fi
else
    # stdin mode: execute piped script in a non-login shell
    if command -v runuser >/dev/null 2>&1; then
        runuser -u devuser -- sh
    elif command -v su >/dev/null 2>&1; then
        su devuser -c "exec sh"
    elif command -v busybox >/dev/null 2>&1 && busybox su --help >/dev/null 2>&1; then
        busybox su devuser -c "exec sh"
    else
        echo "Error: cannot run as devuser — no runuser, su, or busybox su found" >&2
        exit 1
    fi
fi
