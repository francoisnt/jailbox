#!/bin/bash
set -euo pipefail
[[ $# == 1 ]]
printf 'core:%s\n' "$1" >> "$FAKE_TRACE"
env -0 > "$FAKE_TRACE.$1.env"
case "$1" in
    up) printf 'up output\n'; exit "${FAKE_UP_STATUS:-0}" ;;
    connection-info) cat "$FAKE_RECORDS"; exit "${FAKE_CONNECTION_STATUS:-0}" ;;
    *) exit 98 ;;
esac
