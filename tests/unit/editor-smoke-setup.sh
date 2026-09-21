#!/bin/bash
# Test-only preferences must be seeded after up and before real editor launch.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export SMOKE_TRACE="$tmp/trace" SMOKE_SETTINGS="$tmp/settings"
# shellcheck disable=SC2329 # Exported to the editor fixture before the reopen scenario.
fake_editor() { printf 'editor %s\n' "$*" >> "$SMOKE_TRACE"; }
fake_cli() {
    printf 'cli %s\n' "$*" >> "$SMOKE_TRACE"
    cat > "$SMOKE_SETTINGS"
    return "${SMOKE_EXEC_STATUS:-0}"
}
export -f fake_editor fake_cli
export JAILBOX_TEST_EDITOR_REAL=fake_editor JAILBOX_TEST_CLI=fake_cli
# exec requires executables, so expose the recording functions through Bash.
printf '#!/bin/bash\nfake_editor "$@"\n' > "$tmp/editor"
chmod 755 "$tmp/editor"
export JAILBOX_TEST_EDITOR_REAL="$tmp/editor"
wrapper="$ROOT/tests/fixtures/editor-smoke/editor.sh"
bash "$wrapper" --list-extensions
[[ "$(cat "$SMOKE_TRACE")" = 'editor --list-extensions' ]]
[[ ! -e "$SMOKE_SETTINGS" ]]
: > "$SMOKE_TRACE"
bash "$wrapper" --folder-uri test-target
[[ "$(cat "$SMOKE_TRACE")" = $'cli exec /usr/local/bin/jailbox-write-editor-settings\neditor --disable-workspace-trust --folder-uri test-target' ]]
[[ "$(cat "$SMOKE_SETTINGS")" = '{"security.workspace.trust.enabled":false,"task.allowAutomaticTasks":"on"}' ]]
: > "$SMOKE_TRACE"
export SMOKE_EXEC_STATUS=23
status=0
bash "$wrapper" --folder-uri test-target || status=$?
[[ "$status" = 23 ]]
[[ "$(cat "$SMOKE_TRACE")" = 'cli exec /usr/local/bin/jailbox-write-editor-settings' ]]

# Extract the real fixture writer; config must leave bootstrap hosts to frontend.
# shellcheck disable=SC1090
source <(sed -n '/^write_fixture() {/,/^close_editor_workspace() {/ { /^close_editor_workspace() {/d; p; }' "$ROOT/tests/e2e/editor-smoke.sh")
declare -F write_fixture >/dev/null
stage_test_image() { printf 'test-image\n'; }
# shellcheck disable=SC2329 # Called by the extracted fixture writer before replacement.
editor_bin() { printf '/test/codium\n'; }
# shellcheck disable=SC2034 # Consumed by the extracted fixture writer.
SCRIPT_DIR="$ROOT/tests/e2e"
# shellcheck disable=SC2034 # Consumed by the extracted fixture writer.
TASK_LABEL=test-task
write_fixture "$tmp/project" egress test-run
grep -qx 'EDITOR=codium' "$tmp/project/jailbox.conf"
grep -qx 'EGRESS_ALLOW=api.ipify.org' "$tmp/project/jailbox.conf"

# Reopening uses the real editor directly, outside the initial-launch wrapper.
# Exercise that path so test trust policy survives the bootstrap window closing.
# shellcheck disable=SC1090
source <(sed -n '/^activate_proof_extension() {/,/^}/p' "$ROOT/tests/e2e/editor-smoke.sh")
declare -F activate_proof_extension >/dev/null
editor_bin() { printf '%s\n' "$tmp/editor"; }
jailbox_editor_user_data() { printf '%s\n' "$tmp/profile with spaces"; }
snapshot_remote_editor_connections() { printf 'previous-connection\n'; }
wait_for_remote_editor_ready() {
    [[ "$1" = "$tmp/project" && "$2" = test-host && "$3" = 1 && "$4" = previous-connection ]] || return 1
    printf 'ready\n' >> "$SMOKE_TRACE"
}
fake_editor() {
    printf '%s\0' "$@" > "$SMOKE_TRACE.argv"
    printf 'editor\n' >> "$SMOKE_TRACE"
    return "${SMOKE_EDITOR_STATUS:-0}"
}
export -f fake_editor
# shellcheck disable=SC2034 # Consumed by the extracted production reopen function.
EXT_ACTIVATION_MARKER=activated EDITOR_TIMEOUT=1
touch "$tmp/project/$EXT_ACTIVATION_MARKER"
: > "$SMOKE_TRACE"
activate_proof_extension "$tmp/project" test-host
printf '%s\0' --user-data-dir "$tmp/profile with spaces" --new-window \
    --disable-workspace-trust --remote ssh-remote+test-host /home/jailbox/project > "$tmp/expected-argv"
cmp "$tmp/expected-argv" "$SMOKE_TRACE.argv"
[[ "$(cat "$SMOKE_TRACE")" = $'editor\nready' ]]
: > "$SMOKE_TRACE"
export SMOKE_EDITOR_STATUS=24
if activate_proof_extension "$tmp/project" test-host; then exit 1; fi
[[ "$(cat "$SMOKE_TRACE")" = editor ]]
printf 'PASS: reopened editor retains test trust policy and refuses launch failures\n'
printf 'PASS: editor smoke setup ordering, failure propagation, and minimal host policy\n'
