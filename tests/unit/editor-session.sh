#!/bin/bash
# Exercise editor lifecycle guards without a display or remote server.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Source the same guarded runner used by stage workers, then install test stubs.
# shellcheck source=tests/e2e/editor-smoke.sh
source "$ROOT/tests/e2e/editor-smoke.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

jailbox_editor_user_data() { printf '/test/editor-profile\n'; }
editor_profile_pids() { :; }
close_editor_workspace() { fail 'cleanup launched an absent editor'; }
terminate_editor_profile() { fail 'cleanup tried to kill an absent editor'; }
cleanup_editor_workspace /test/project sandbox
cleanup_editor_workspace /test/project sandbox

# Advance the polling deadline without sleeping. Old records, even after log
# rotation removes some of them, must never count as a fresh connection.
sleep() { SECONDS=$((SECONDS + 1)); }
ready_at=0
remote_editor_connections() {
    if (( SECONDS < ready_at )); then printf 'partial\n'; return 1; fi
    printf '%s\n' "$records"
}
baseline=$'connection-a Launched Extension Host Process 100\nconnection-b Launched Extension Host Process 200'
records=$baseline
if wait_for_remote_editor_ready /test/project sandbox 1 "$baseline"; then
    fail 'accepted stale connection records'
fi
records=''
if wait_for_remote_editor_ready /test/project sandbox 1 "$baseline"; then
    fail 'accepted empty connection records'
fi
records='connection-b Launched Extension Host Process 200'
if wait_for_remote_editor_ready /test/project sandbox 1 "$baseline"; then
    fail 'accepted log rotation as a fresh connection'
fi
records='connection-c Launched Extension Host Process 300'
wait_for_remote_editor_ready /test/project sandbox 1 "$baseline" || fail 'rejected a new connection'
wait_for_remote_editor_ready /test/project sandbox 1 || fail 'rejected initial attachment'

# A failed SSH read may emit partial output; only a successful snapshot counts.
ready_at=$((SECONDS + 2))
snapshot=$(snapshot_remote_editor_connections /test/project sandbox) || fail 'did not retry snapshot'
[[ "$snapshot" = "$records" ]] || fail 'snapshot included failed-read output'
ready_at=$((SECONDS + 100))
if snapshot=$(snapshot_remote_editor_connections /test/project sandbox 2>/dev/null); then
    fail 'accepted persistent snapshot failure'
fi
[[ -z "$snapshot" ]] || fail 'failed snapshot emitted connection records'
ready_at=0
records=''
if snapshot_remote_editor_connections /test/project sandbox >/dev/null 2>&1; then
    fail 'accepted an empty bootstrap snapshot'
fi
printf 'PASS: editor cleanup and fresh-connection guards\n'
