#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# shellcheck source=src/host/frontend/editor.sh
source "$ROOT/src/host/frontend/editor.sh"

TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

EDITOR_CONNECTION[ssh_config]='/host/config with spaces'
EDITOR_CONNECTION[ssh_host]=jailbox-test

mkdir "$TMP/bin"
cp "$ROOT/tests/fixtures/editor-client/watcher-ssh.sh" "$TMP/bin/ssh"
chmod 700 "$TMP/bin/ssh"

export PATH="$TMP/bin:$PATH" WATCHER_ARGS="$TMP/args"
export WATCHER_LIMIT=65536 WATCHER_STATUS=0

output=$(warn_low_inotify_watch_limit 2>&1)
[[ "$output" == *'65536 in the container'* && "$output" == *'Podman VM on macOS'* &&
    "$output" == *'/etc/sysctl.d/60-jailbox-inotify.conf'* ]]

mapfile -t args < "$TMP/args"
[[ ${args[0]} == -n && ${args[1]} == -F && ${args[2]} == '/host/config with spaces' &&
    ${args[3]} == -o && ${args[4]} == BatchMode=yes &&
    ${args[11]} == jailbox-test && ${args[12]} == 'cat /proc/sys/fs/inotify/max_user_watches' ]]

# Unavailable or malformed diagnostics must never block editor attachment.
for WATCHER_LIMIT in 524288 1048576 '' invalid '65536 extra' 999999999999999999999999999999; do
    [[ -z $(warn_low_inotify_watch_limit 2>&1) ]]
done

WATCHER_LIMIT=065536
[[ $(warn_low_inotify_watch_limit 2>&1) == *'065536 in the container'* ]]

WATCHER_LIMIT=65536
WATCHER_STATUS=255
[[ -z $(warn_low_inotify_watch_limit 2>&1) ]]

EDITOR_CONNECTION=()
rm "$TMP/args"
[[ -z $(warn_low_inotify_watch_limit 2>&1) && ! -e "$TMP/args" ]]

printf 'PASS: remote watcher diagnostic and advisory failures\n'
