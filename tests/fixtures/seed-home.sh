#!/bin/bash
set -euo pipefail
chown 0:0 "$1"
chmod 755 "$1"
printf "retained\n" > "$1/lifecycle-marker"
chmod 644 "$1/lifecycle-marker"
[[ $(stat -c "%u:%g:%a" "$1") = 0:0:755 ]]
