#!/bin/bash
set -euo pipefail
name=${0##*/}
case "$name" in
    code) extension=ms-vscode-remote.remote-ssh ;;
    codium) extension=jeanp413.open-remote-ssh ;;
    *) exit 98 ;;
esac
[[ $1 == --extensions-dir ]]
if [[ $3 == --list-extensions && $# == 3 ]]; then
    printf 'inventory:%s\n' "$name" >> "$FAKE_TRACE"
    printf '%s' "$2" > "$FAKE_TRACE.inventory-dir"
    printf '%s\n' "${FAKE_INVENTORY-$extension}"
    exit "${FAKE_INVENTORY_STATUS:-0}"
fi
[[ $3 == --user-data-dir && $5 == --remote && $# == 7 ]]
printf 'launch:%s\n' "$name" >> "$FAKE_TRACE"
printf '%s\0' "$@" > "$FAKE_TRACE.argv"
exit "${FAKE_EDITOR_STATUS:-0}"
