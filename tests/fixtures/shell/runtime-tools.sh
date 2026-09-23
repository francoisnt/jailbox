#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    jailbox)
        printf 'ssh_config\t/test/config\0ssh_host\ttest\0remote_path\t/home/jailbox/project\0project_id\ttest\0proxy_url\thttp://10.0.0.2:8888\0'
        ;;
    python3)
        printf '%s\n' "$*" >> "$TERMINAL_TEST_TRACE"
        if [[ "$*" = *--exercise* ]]; then exit "${TERMINAL_TEST_STATUS:-0}"; fi
        ;;
    podman)
        printf '%s\n' "$*" >> "$TERMINAL_TEST_TRACE"
        cat >/dev/null
        ;;
    *) exit 1 ;;
esac
