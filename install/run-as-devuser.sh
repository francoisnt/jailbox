#!/bin/sh
# Portable helper: run a shell command as the dev user (DEV_USER, defaulting to devuser).
# Usage:
#   sh run-as-devuser.sh '<shell command>'
#   printf '%s\n' '<shell script>' | sh run-as-devuser.sh
set -e

COMMAND="${1:-}"

_DEV_USER="${DEV_USER:-devuser}"

if [ -n "$COMMAND" ]; then
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$_DEV_USER" -- sh -lc "$COMMAND"
    elif command -v su >/dev/null 2>&1; then
        su "$_DEV_USER" -c "$COMMAND"
    elif command -v busybox >/dev/null 2>&1 && busybox su --help >/dev/null 2>&1; then
        busybox su "$_DEV_USER" -c "$COMMAND"
    else
        echo "Error: cannot run as $_DEV_USER — no runuser, su, or busybox su found" >&2
        exit 1
    fi
else
    # stdin mode: execute piped script in a non-login shell
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$_DEV_USER" -- sh
    elif command -v su >/dev/null 2>&1; then
        su "$_DEV_USER" -c "exec sh"
    elif command -v busybox >/dev/null 2>&1 && busybox su --help >/dev/null 2>&1; then
        busybox su "$_DEV_USER" -c "exec sh"
    else
        echo "Error: cannot run as $_DEV_USER — no runuser, su, or busybox su found" >&2
        exit 1
    fi
fi
