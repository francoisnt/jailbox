#!/bin/sh
# Run through public exec; success requires both positive and negative probes.
set -eu
cd /home/jailbox/project
test "$(cat protected-policy)" = protected
printf 'shared-write\n' > from-container
printf 'retained\n' > "$HOME/smoke-home"
if printf 'changed\n' > protected-policy; then
    echo 'Protected file was writable' >&2
    exit 1
fi
test "$(cat protected-policy)" = protected
test "$(cat from-container)" = shared-write
test "$(cat "$HOME/smoke-home")" = retained
