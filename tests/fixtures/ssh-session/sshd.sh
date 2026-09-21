#!/bin/bash
set -euo pipefail
printf '%s\n' "$@" >> "$SESSION_TRACE"
[[ ! ${HTTP_PROXY+x} && ! ${HTTPS_PROXY+x} && ! ${http_proxy+x} &&
   ! ${https_proxy+x} && ! ${NO_PROXY+x} && ! ${no_proxy+x} ]] || exit 90
case "$1" in
    -t) exit "${SESSION_CHECK_STATUS:-0}" ;;
    -D) exit "${SESSION_START_STATUS:-0}" ;;
    *) exit 91 ;;
esac
