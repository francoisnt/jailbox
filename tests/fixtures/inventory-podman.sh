#!/usr/bin/env bash
set -euo pipefail
inventory_podman() {
    printf '%s\n' "$*" >> "$TEST_CALLS"
    case "$1:$2:$3" in
        "container:exists:$TEST_PREFIX"|"container:exists:$TEST_PREFIX-proxy"|\
        "network:exists:$TEST_PREFIX-net"|"network:exists:$TEST_PREFIX-net-internal"|\
        "network:exists:$TEST_PREFIX-net-external"|"volume:exists:$TEST_PREFIX-home")
            if [[ "$TEST_FAULT" = "$3" ]]; then printf '%s' "$TEST_PARTIAL"; return 125; fi
            [[ " $TEST_PRESENT " = *" $3 "* ]] && return 0
            return 1
            ;;
        "container:inspect:$TEST_PREFIX")
            [[ "$#" = 5 && "$4" = --format && "$5" = '{{.State.Running}}' ]] || return 98
            if [[ "$TEST_FAULT" = inspect ]]; then printf '%s' "$TEST_PARTIAL"; return 125; fi
            printf '%s\n' "$TEST_RUNNING"
            ;;
        *) echo 'unexpected Podman operation' >&2; return 99 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    inventory_podman "$@"
fi
