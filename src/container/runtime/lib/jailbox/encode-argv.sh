#!/bin/bash
# Used by the host SSH command and the sandbox forwarding client.
set -euo pipefail

command_description=$1
shift
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

{
    IFS= read -r frame_limit && IFS= read -r frame_grammar
} < "${BASH_SOURCE[0]%/*}/argv-frame" || fail "could not read $command_description argument format"

[[ $# -gt 0 && -n "$1" ]] || fail "invalid $command_description argument encoding"
frame=$(printf '%s\0' "$@" | base64) || fail "could not encode $command_description arguments"
frame=${frame//$'\n'/}
[[ ${#frame} -le $frame_limit ]] || fail "argument list too long for $command_description"
LC_ALL=C
[[ "$frame" =~ $frame_grammar ]] || fail "invalid $command_description argument encoding"
printf '%s' "$frame"
