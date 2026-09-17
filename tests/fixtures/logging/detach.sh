#!/bin/bash
set -euo pipefail
sleep 30 >/dev/null 2>&1 &
printf '%s\n' "$!" > "$1"
printf 'command finished\n'
