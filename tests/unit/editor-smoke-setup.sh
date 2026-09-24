#!/bin/bash
# Test-only preferences must be seeded after up and before real editor launch.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/e2e/editor-smoke.sh
source "$ROOT/tests/e2e/editor-smoke.sh"
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
# shellcheck disable=SC2031 # Fresh fixture values, independent of the runner's subshell exports.
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

# Config must leave bootstrap hosts to frontend.
stage_test_image() { printf 'test-image\n'; }
# shellcheck disable=SC2329 # Called by the runner fixture writer before replacement.
editor_bin() { printf '/test/codium\n'; }
# shellcheck disable=SC2034 # Consumed by the runner fixture writer.
SCRIPT_DIR="$ROOT/tests/e2e"
# shellcheck disable=SC2034 # Consumed by the runner fixture writer.
TASK_LABEL=test-task
write_fixture "$tmp/project" egress test-run
grep -qx 'EDITOR=codium' "$tmp/project/jailbox.conf"
grep -qx 'EGRESS_ALLOW=api.ipify.org' "$tmp/project/jailbox.conf"

# Reopening uses the real editor directly, outside the initial-launch wrapper.
# Exercise that path so test trust policy survives the bootstrap window closing.
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
# shellcheck disable=SC2034 # Consumed by the runner reopen function.
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

# Later launches keep the test-only trust flag without reseeding through stale
# machine policy. This is required when a workflow changes effective hosts.
: > "$SMOKE_TRACE"
unset SMOKE_EDITOR_STATUS
JAILBOX_TEST_SEED_SETTINGS=0 bash "$wrapper" --folder-uri switched
[[ $(cat "$SMOKE_TRACE") == editor ]]

# Reopen/resume clears all previous proof before invoking the public frontend;
# no stale task result can establish a successful new editor session.
JAILBOX_DIR=$ROOT
# shellcheck source=tests/lib/editor/workflows.sh
source "$ROOT/tests/lib/editor/workflows.sh"
PROOF_FILE=proof EXT_ACTIVATION_MARKER=activated EXT_TASK_RESULT=task-result
cleanup_editor_workspace() { printf 'close\n' >> "$SMOKE_TRACE"; }
podman() { [[ $* == 'stop test-host' ]] || return 91; printf 'stop\n' >> "$SMOKE_TRACE"; }
editor_public_launch() {
    [[ ! -e "$1/$PROOF_FILE" && ! -e "$1/$EXT_ACTIVATION_MARKER" && ! -e "$1/$EXT_TASK_RESULT" && ! -e "$1/.jailbox-editor-settings.json" ]] || return 90
    printf 'public-launch\n' >> "$SMOKE_TRACE"
    return "${SMOKE_LAUNCH_STATUS:-0}"
}
wait_for_task_result() { printf 'task\n' >> "$SMOKE_TRACE"; }
validate_task_result() { printf 'validate-task\n' >> "$SMOKE_TRACE"; }
validate_proof() { printf 'validate-proof\n' >> "$SMOKE_TRACE"; }
pass() { :; }
for mode in reopen resume; do
    for artifact in "$PROOF_FILE" "$EXT_ACTIVATION_MARKER" "$EXT_TASK_RESULT" .jailbox-editor-settings.json; do
        touch "$tmp/project/$artifact"
    done
    : > "$SMOKE_TRACE"
    editor_reopen "$tmp/project" egress test-host "$mode"
    expected=close
    [[ $mode != resume ]] || expected+=$'\nstop'
    expected+=$'\npublic-launch\nready\ntask\nvalidate-task\nvalidate-proof'
    [[ $(cat "$SMOKE_TRACE") == "$expected" ]]
done
: > "$SMOKE_TRACE"
export SMOKE_LAUNCH_STATUS=25
if editor_reopen "$tmp/project" egress test-host reopen; then exit 1; fi
[[ $(cat "$SMOKE_TRACE") == $'close\npublic-launch' ]]
printf 'PASS: public reopen/resume requires fresh task proof and propagates launch failure\n'

# Switching policy preserves the selected fixture image rather than assuming
# that the egress stage always uses Debian.
editor_policy_fixture "$tmp/policy" different-stage-image codium example.com jailbox.conf
grep -qx 'DEV_IMAGE=different-stage-image' "$tmp/policy"

# A network can disappear between listing and inspection. Only confirmed
# absence permits continuing to another network with the required subnet.
LOG_DIR="$tmp/logs"
mkdir "$LOG_DIR"
jailbox_project_hash_for_path() { printf 'fixture-hash\n'; }
jailbox_project_hash_port_offset() { printf '4\n'; }
ledger_record() { [[ $* == 'network test-host-editor-collision' ]] || return 1; }
podman() {
    case "$1 $2" in
        'network create') return 125 ;;
        'network ls') printf 'disappearing\noccupied\n' ;;
        'network inspect')
            if [[ $3 == disappearing ]]; then echo 'inspect failed' >&2; return 125; fi
            [[ $3 == occupied ]] || return 92
            printf '10.240.5.0/24\n'
            ;;
        'network exists') return "$NETWORK_EXISTS_STATUS" ;;
        *) return 93 ;;
    esac
}
NETWORK_EXISTS_STATUS=1
occupy_editor_subnet "$tmp/project" test-host
[[ -s "$LOG_DIR/test-host.network-names" && -s "$LOG_DIR/test-host.subnets" ]]
[[ ! -e "$tmp/project/network-names" && ! -e "$tmp/project/subnets" ]]
for NETWORK_EXISTS_STATUS in 0 125; do
    if occupy_editor_subnet "$tmp/project" test-host > "$tmp/network-error" 2>&1; then
        echo 'FAIL: network inspection error was ignored' >&2; exit 1
    fi
    grep -q 'inspect failed' "$tmp/network-error"
done
printf 'PASS: collision fixture isolates diagnostics and tolerates only confirmed disappearance\n'
