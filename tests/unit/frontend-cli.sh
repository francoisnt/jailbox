#!/bin/bash
# Real public dispatch, child core processes, and shared attachment policy.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$FIXTURE/home" FAKE_TRACE="$FIXTURE/editor-trace"
export JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE="$FIXTURE/no-limit"
mkdir "$HOME"
cp "$ROOT/tests/fixtures/editor-client/editor.sh" "$FIXTURE/bin/code"
chmod 755 "$FIXTURE/bin/code"
printf 'DEV_IMAGE=localhost/convergence\nEDITOR=code\nEGRESS_ALLOW=example.com\n' > "$FIXTURE/project/jailbox.conf"
# The public file validator must delegate to core with no runtime prerequisites.
mkdir "$FIXTURE/local-bin"
for tool in bash dirname readlink realpath env; do
    ln -s "$(command -v "$tool")" "$FIXTURE/local-bin/$tool"
done
PATH="$FIXTURE/local-bin" launch --config jailbox.conf validate
[[ ! -s "$CONVERGENCE_LOG" ]]
printf 'DEV_IMAGE=selected\nEDITOR=code\n' > "$FIXTURE/project/selected.conf"
PATH="$FIXTURE/local-bin" launch --config selected.conf validate
printf 'DEV_IMAGE=selected\nREADONLY_PATHS=missing\n' > "$FIXTURE/project/selected.conf"
if PATH="$FIXTURE/local-bin" launch --config selected.conf validate; then fail 'selected file was ignored'; fi
rm "$FIXTURE/project/selected.conf"
# Inventory must run before any lifecycle call, including reopening.
if FAKE_INVENTORY_STATUS=42 launch > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'inventory failure accepted'; fi
[[ ! -s "$CONVERGENCE_LOG" ]]
: > "$FAKE_TRACE"
JAILBOX_CONFIG_DEV_IMAGE=ignored-secret JAILBOX_EDITOR=invalid EDITOR=invalid launch > "$FIXTURE/out" 2> "$FIXTURE/error"
grep -q JAILBOX_CONFIG_DEV_IMAGE "$FIXTURE/error"
if grep -q ignored-secret "$FIXTURE/error"; then fail 'ignored value leaked'; fi
[[ $(cat "$FAKE_TRACE") = $'inventory:code\nlaunch:code' ]]
# The equivalent machine policy reaches connection-info, exec, and shell.
export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
export JAILBOX_CONFIG_EGRESS_ALLOW_1=update.code.visualstudio.com
export JAILBOX_CONFIG_EGRESS_ALLOW_2=vscode.download.prss.microsoft.com
export JAILBOX_CONFIG_EGRESS_ALLOW_3=main.vscode-cdn.net
export JAILBOX_CONFIG_EGRESS_ALLOW_4=vo.msecnd.net
launch connection-info > "$FIXTURE/records"
export CONVERGENCE_EXEC_HELPER="$FIXTURE/exec-helper"
# shellcheck disable=SC2016 # The decoder expands its fixture directory.
sed 's|^cd /home/jailbox/project |cd "$CONVERGENCE_ENGINE" |' "$ROOT/container/runtime/bin/jailbox-exec-argv" > "$CONVERGENCE_EXEC_HELPER"
# shellcheck disable=SC2016 # Literal argv must survive shell syntax unchanged.
args=('' 'space here' '"quoted"' '$literal' $'line\nend')
printf '%s\0' "${args[@]}" > "$FIXTURE/expected"
launch exec printf '%s\0' "${args[@]}" > "$FIXTURE/actual"
cmp "$FIXTURE/expected" "$FIXTURE/actual"
printf 'binary\0stdin\377\n' > "$FIXTURE/input"
launch exec cat < "$FIXTURE/input" > "$FIXTURE/actual"
cmp "$FIXTURE/input" "$FIXTURE/actual"
python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$FIXTURE/project" --output "$FIXTURE/shell" -- "$ROOT/jailbox" shell
# Include editor hosts explicitly, reorder and repeat: both paths now agree.
printf 'DEV_IMAGE=localhost/convergence\nEDITOR=code\nEGRESS_ALLOW=vo.msecnd.net,example.com,main.vscode-cdn.net,update.code.visualstudio.com,vscode.download.prss.microsoft.com,example.com\n' > "$FIXTURE/project/jailbox.conf"
: > "$CONVERGENCE_LOG"
launch --no-editor > "$FIXTURE/out" 2> "$FIXTURE/error"
launch > "$FIXTURE/out" 2> "$FIXTURE/error"
if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then fail 'equivalent policy recreated resources'; fi
before=$(snapshot)
: > "$CONVERGENCE_LOG"
export JAILBOX_CONFIG_EGRESS_ALLOW_5=changed.example.com
for command in connection-info exec; do
    args=(); [[ "$command" != exec ]] || args=(true)
    if launch "$command" "${args[@]}" > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'changed policy attached'; fi
    grep -q 'jailbox stop' "$FIXTURE/error"
done
python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$FIXTURE/project" --output "$FIXTURE/shell" --expect refuse -- "$ROOT/jailbox" shell
assert_no_mutation
# File change refuses before editor launch; the frontend never repairs state.
printf 'DEV_IMAGE=localhost/convergence\nEDITOR=code\nEGRESS_ALLOW=changed.example.com\n' > "$FIXTURE/project/jailbox.conf"
: > "$FAKE_TRACE"
if launch > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'changed file policy launched'; fi
[[ $(cat "$FAKE_TRACE") = 'inventory:code' ]]
assert_no_mutation
printf 'PASS: public file validation, editor sequencing, equivalent reuse, and machine attachment\n'
