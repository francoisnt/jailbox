#!/bin/bash
set -euo pipefail
    grep -F "$1" "$HOME/.curlrc" >/dev/null &&
    grep -F "$1" "$HOME/.wgetrc" >/dev/null &&
    response=$(curl -q --noproxy "" --proxy "$1" -s --connect-timeout 3 --max-time 8 -o /dev/null -w "%{http_code}" http://jailbox-fault-check.invalid/) &&
    test "$response" = 403
