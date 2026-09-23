#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/frontend/file-policy.sh
source "$ROOT/src/host/frontend/file-policy.sh"
# shellcheck source=src/host/frontend/editor.sh
source "$ROOT/src/host/frontend/editor.sh"
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/project" "$TMP/home" "$TMP/staging"
for tool in realpath mktemp rm dirname cat chmod mv env mkdir; do
    ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
for editor in code codium; do
    cp "$ROOT/tests/fixtures/editor-client/editor.sh" "$TMP/bin/$editor"
    chmod 700 "$TMP/bin/$editor"
done
cp "$ROOT/tests/fixtures/editor-client/core.sh" "$TMP/core"
chmod 700 "$TMP/core"
export JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE=$TMP/absent
export HOME=$TMP/home TMPDIR=$TMP/staging FAKE_TRACE=$TMP/trace FAKE_RECORDS=$TMP/records
export JAILBOX_EDITOR=invalid EDITOR=invalid
unset XDG_STATE_HOME
ssh_config='/host/a "quoted"\ssh config é 😀'
remote_path='/remote/a "quoted"\project é 😀'
write_records() {
    printf 'ssh_config\t%s\0ssh_host\tjailbox-sample-012345abcdef\0remote_path\t%s\0project_id\t012345abcdef\0proxy_url\t%s\0' \
        "$ssh_config" "$remote_path" "${1:-}" > "$FAKE_RECORDS"
}
launch() {
    : > "$FAKE_TRACE"
    PATH="$TMP/bin" launch_file_editor "$TMP/core" "$TMP/project" > "$TMP/out" 2> "$TMP/err"
}
assert_refused() {
    local expected=$1
    if launch; then fail "accepted $expected"; fi
    grep -Fq -- "$expected" "$TMP/err" || { cat "$TMP/err"; fail 'missing refusal context'; }
    if grep -q '^launch:' "$FAKE_TRACE"; then fail 'editor launched after refusal'; fi
}
no_machine_calls() {
    if grep -q '^core:' "$FAKE_TRACE"; then fail 'preflight failure invoked core'; fi
}
child_has() {
    local entry
    while IFS= read -r -d '' entry; do
        [[ "$entry" != "$1" ]] || return 0
    done < "$FAKE_TRACE.up.env"
    fail "missing child environment $1"
}
settings=$HOME/.local/state/jailbox/editor-profiles/012345abcdef/User/settings.json
write_records http://10.0.0.2:8888
printf 'EDITOR=code\nEGRESS_ALLOW=example.org\n' > "$TMP/project/jailbox.conf"
launch || { cat "$TMP/err" >&2; exit 1; }
[[ $(cat "$FAKE_TRACE") == $'inventory:code\ncore:up\ncore:connection-info\nlaunch:code' ]]
cmp "$FAKE_TRACE.up.env" "$FAKE_TRACE.connection-info.env"
for expected in '0=example.org' '1=update.code.visualstudio.com' '2=vscode.download.prss.microsoft.com' '3=main.vscode-cdn.net' '4=vo.msecnd.net'; do
    child_has "JAILBOX_CONFIG_EGRESS_ALLOW_$expected"
done
mapfile -d '' -t argv < "$FAKE_TRACE.argv"
[[ ${argv[0]} == --extensions-dir && ${argv[1]} == "$(cat "$FAKE_TRACE.inventory-dir")" && ${argv[2]} == --user-data-dir && ${argv[3]} == "$HOME/.local/state/jailbox/editor-profiles/012345abcdef" && ${argv[4]} == --remote && ${argv[5]} == ssh-remote+jailbox-sample-012345abcdef && ${argv[6]} == "$remote_path" ]]
python3 "$ROOT/tests/lib/editor/check-settings.py" "$settings" "$ssh_config" http://10.0.0.2:8888
# Compatible trailing fields stay opaque through the complete launch path,
# including values that would be invalid in required paths or JSON settings.
cp "$FAKE_TRACE.argv" "$TMP/expected-argv"
cp "$settings" "$TMP/expected-settings"
printf 'future_field\topaque\tvalue\n\377\0' >> "$FAKE_RECORDS"
launch
cmp "$TMP/expected-argv" "$FAKE_TRACE.argv"
cmp "$TMP/expected-settings" "$settings"
[[ $(cat "$FAKE_TRACE") == $'inventory:code\ncore:up\ncore:connection-info\nlaunch:code' ]]
write_records http://10.0.0.2:8888
# Relocation changes both publication and the editor argument, including spaces.
# shellcheck disable=SC2030 # Each scenario intentionally isolates its state home.
(
    export XDG_STATE_HOME="$TMP/relocated state"
    launch
    mapfile -d '' -t argv < "$FAKE_TRACE.argv"
    [[ ${argv[3]} == "$XDG_STATE_HOME/jailbox/editor-profiles/012345abcdef" ]]
    python3 "$ROOT/tests/lib/editor/check-settings.py" \
        "${argv[3]}/User/settings.json" "$ssh_config" http://10.0.0.2:8888
)
XDG_STATE_HOME='' launch
mapfile -d '' -t argv < "$FAKE_TRACE.argv"
[[ ${argv[3]} == "$HOME/.local/state/jailbox/editor-profiles/012345abcdef" ]]
[[ -f "$settings" ]]
# shellcheck disable=SC2031 # Each scenario supplies its own state home.
for state_home in relative-state $'/tmp/bad\nstate'; do
    (export XDG_STATE_HOME="$state_home"; assert_refused 'profile state home must be an absolute'; no_machine_calls)
done
# Reopening checks current prerequisites again rather than caching preflight.
launch
[[ $(head -1 "$FAKE_TRACE") == inventory:code ]]
# Empty/unset file EDITOR discovers Codium first, then Code. Neither inherited
# editor variable participates, even when it names a different valid editor.
for file_editor in '' 'EDITOR='; do
    printf '%s\nEGRESS_ALLOW=example.org\n' "$file_editor" > "$TMP/project/jailbox.conf"
    JAILBOX_EDITOR=code EDITOR=code launch
    [[ $(head -1 "$FAKE_TRACE") == inventory:codium ]]
    child_has JAILBOX_CONFIG_EGRESS_ALLOW_1=github.com
    child_has JAILBOX_CONFIG_EGRESS_ALLOW_2=githubusercontent.com
done
mv "$TMP/bin/codium" "$TMP/codium"
launch
[[ $(head -1 "$FAKE_TRACE") == inventory:code ]]
mv "$TMP/bin/code" "$TMP/code"
assert_refused 'missing binaries: codium, code'
no_machine_calls
mv "$TMP/codium" "$TMP/bin/codium"
printf 'EDITOR=code\n' > "$TMP/project/jailbox.conf"
assert_refused 'file EDITOR=code; resolved editor: code (not found)'
grep -q ms-vscode-remote.remote-ssh "$TMP/err"
no_machine_calls
mv "$TMP/code" "$TMP/bin/code"
# Both selected editor and the selection precedence appear on each preflight
# refusal. Plausible stdout cannot rescue a failed inventory command.
export FAKE_INVENTORY=missing.extension
assert_refused 'file EDITOR=code; resolved editor:'
grep -q 'missing required extension ms-vscode-remote.remote-ssh' "$TMP/err"
no_machine_calls
printf 'EDITOR=\n' > "$TMP/project/jailbox.conf"
assert_refused 'automatic discovery (codium, then code); resolved editor:'
grep -q 'missing required extension jeanp413.open-remote-ssh' "$TMP/err"
no_machine_calls
printf 'EDITOR=code\n' > "$TMP/project/jailbox.conf"
export FAKE_INVENTORY=ms-vscode-remote.remote-ssh FAKE_INVENTORY_STATUS=42
assert_refused 'extension inventory failed'
no_machine_calls
unset FAKE_INVENTORY FAKE_INVENTORY_STATUS
# Multiple discoverable failures are reported together before a machine call.
(
    unset FAKE_INVENTORY_STATUS
    export FAKE_INVENTORY=missing HOME=relative-home
    assert_refused 'profile home must be an absolute'
    grep -q 'missing required extension ms-vscode-remote.remote-ssh' "$TMP/err"
    no_machine_calls
)
# The fixture refuses every unsupported option, including version queries.
# Different unrelated versioned inventory entries must not gate or warn.
for version in 0.0.1 999.999.999; do
    FAKE_INVENTORY=$'ms-vscode-remote.remote-ssh\nother.extension@'"$version" launch
    [[ ! -s "$TMP/err" ]]
done
printf 'EDITOR=invalid\n' > "$TMP/project/jailbox.conf"
assert_refused 'invalid EDITOR'
no_machine_calls
# Headless APIs are covered by file-policy tests; an unfiltered editor launch
# also must not add bootstrap hosts or editor proxy/terminal settings.
printf 'EDITOR=codium\nEGRESS_ALLOW=\n' > "$TMP/project/jailbox.conf"
write_records
launch
child_has JAILBOX_CONFIG_EGRESS_ALLOW=
python3 "$ROOT/tests/lib/editor/check-settings.py" "$settings" "$ssh_config" ''

# Failures stop dependent work and leave an accepted settings file unchanged.
printf 'original\n' > "$settings"
export FAKE_UP_STATUS=41
status=0
launch || status=$?
[[ $status == 41 && $(cat "$FAKE_TRACE") == $'inventory:codium\ncore:up' ]]
unset FAKE_UP_STATUS
export FAKE_CONNECTION_STATUS=42
status=0
launch || status=$?
[[ $status == 42 && $(cat "$FAKE_TRACE") == $'inventory:codium\ncore:up\ncore:connection-info' ]]
unset FAKE_CONNECTION_STATUS
printf 'unterminated' > "$FAKE_RECORDS"
assert_refused 'unterminated record'
[[ $(cat "$settings") == original ]]
write_records
printf 'project_id\t012345abcdef\0' >> "$FAKE_RECORDS"
assert_refused "duplicate field 'project_id'"
[[ $(cat "$settings") == original ]]
(
    remote_path=relative
    write_records
)
assert_refused "invalid 'remote_path' value"
[[ $(cat "$settings") == original ]]
write_records
(
    # shellcheck disable=SC2329 # Fail the real writer's publication operation.
    mv() { return 43; }
    assert_refused 'could not publish editor settings'
    [[ $(cat "$settings") == original ]]
)
(
    # Non-UTF-8 input cannot become a JSON string; reject before publication.
    ssh_config=$'/host/invalid\377'
    write_records
    assert_refused 'could not publish editor settings'
    [[ $(cat "$settings") == original ]]
)
write_records
[[ -z $(find "$TMP/staging" -type f -print) ]]
(
    # shellcheck disable=SC2329 # Fault injection at connection staging cleanup.
    rm() { return 45; }
    assert_refused 'could not clean temporary connection records'
)
command rm -f -- "$TMP/staging/"*
export FAKE_EDITOR_STATUS=44
status=0
launch || status=$?
[[ $status == 44 ]]
printf 'PASS: editor preflight, policy, public child sequencing, profile, literal argv, and failures\n'
