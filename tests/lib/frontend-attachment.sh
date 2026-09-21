#!/bin/bash
# Runtime transport after a real filtered file/editor launch (editor is stubbed).
set -euo pipefail
ROOT=$1 PROJECT=$2 CONTAINER=$3 OUTPUT=$4
for name in "${!JAILBOX_CONFIG_@}"; do unset "$name"; done
export JAILBOX_CONFIG_DEV_IMAGE=jailbox-test-debian
export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
export JAILBOX_CONFIG_READONLY_PATHS_1=config/runtime.conf
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
export JAILBOX_CONFIG_EGRESS_ALLOW_1=github.com
export JAILBOX_CONFIG_EGRESS_ALLOW_2=githubusercontent.com
cli() { (cd "$PROJECT" && "$ROOT/src/jailbox" "$@"); }
cli connection-info > "$OUTPUT.connection"
# shellcheck disable=SC2016 # Literal arguments must reach the remote process.
args=('' 'space here' '"quoted"' '$literal' 'back\slash' $'line\nend')
printf '%s\0' "${args[@]}" > "$OUTPUT.expected"
cli exec printf '%s\0' "${args[@]}" > "$OUTPUT.actual"
cmp "$OUTPUT.expected" "$OUTPUT.actual"
printf 'binary\0stdin\377\n' > "$OUTPUT.input"
cli exec cat < "$OUTPUT.input" > "$OUTPUT.actual"
cmp "$OUTPUT.input" "$OUTPUT.actual"
bash "$ROOT/tests/lib/shell-runtime.sh" "$ROOT" "$PROJECT" "$CONTAINER" "$OUTPUT.shell"
podman inspect "$CONTAINER" "${CONTAINER}-proxy" > "$OUTPUT.before"
export JAILBOX_CONFIG_EGRESS_ALLOW_3=changed.example.com
if cli exec touch /home/jailbox/project/attachment-must-not-run > "$OUTPUT.out" 2> "$OUTPUT.err"; then
    echo 'changed policy executed a command' >&2; exit 1
fi
grep -q 'jailbox stop' "$OUTPUT.err"
python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$PROJECT" --output "$OUTPUT.refused-shell" --expect refuse -- "$ROOT/src/jailbox" shell
podman inspect "$CONTAINER" "${CONTAINER}-proxy" > "$OUTPUT.after"
cmp "$OUTPUT.before" "$OUTPUT.after"
[[ ! -e "$PROJECT/attachment-must-not-run" ]]
printf 'PASS: filtered frontend policy permits exec/TTY shell and rejects changed attachment without mutation\n'
