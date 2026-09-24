#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export CONVERGENCE_REAL_SLEEP
CONVERGENCE_REAL_SLEEP=$(command -v sleep)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
export CONVERGENCE_EXEC_HELPER="$FIXTURE/exec-helper" CONVERGENCE_DRAIN_STDIN=true
# shellcheck disable=SC2016 # The fixture decoder expands its working directory.
sed 's|^cd /home/jailbox/project |cd "$CONVERGENCE_ENGINE" |' "$ROOT/src/container/runtime/bin/jailbox-exec-argv" > "$CONVERGENCE_EXEC_HELPER"
export TMPDIR="$FIXTURE/tmp"
mkdir -m 700 "$TMPDIR"
fail() { echo "FAIL: $*" >&2; exit 1; }
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
expect_success </dev/null
# Payload/status permutations belong to the real exec handler and decoder.
# Full CLI cases below separately cover attachment, stdin isolation, signals,
# and concurrent callers. Stub only the already-tested attachment preparation.
# shellcheck source=src/host/core/commands/exec.sh
source "$ROOT/src/host/core/commands/exec.sh"
transport_exec() (
    require_command() { command -v "$1" >/dev/null; }
    load_environment_config() { return 0; }
    validate_attachment() { SSH_CONFIG=$GENERATION/ssh_config; CONTAINER_NAME=$PREFIX; }
    die() { fail "$@"; }
    run_exec "$@"
)
# shellcheck disable=SC2016 # Shell syntax is deliberately literal argv data.
args=('' ' ' '"quotes"' "'" '*' $'a\nb\n' $'\377\376' --config --help -- '$(touch forbidden)' '; exit 99')
printf '%s\0' "${args[@]}" > "$FIXTURE/expected"
launch exec -- printf '%s\0' "${args[@]}" > "$FIXTURE/actual"
cmp "$FIXTURE/expected" "$FIXTURE/actual"
printf 'binary\0stdin\377\n' > "$FIXTURE/input"
launch exec cat < "$FIXTURE/input" > "$FIXTURE/output"
cmp "$FIXTURE/input" "$FIXTURE/output"
expected_umask=$(umask)
[[ $(launch exec bash -c umask) = "$expected_umask" ]] || fail 'decoder changed session umask'
for status in 0 1 42 126 127 130 255; do
    result=0
    # shellcheck disable=SC2016 # Expanded by the command being executed.
    transport_exec bash -c 'exit "$1"' bash "$status" > "$FIXTURE/output" 2> "$FIXTURE/error" || result=$?
    [[ "$result" = "$status" ]] || fail "status $status became $result"
done
result=0
launch exec bash -c 'exit 42' > "$FIXTURE/output" 2> "$FIXTURE/error" || result=$?
[[ "$result" = 42 ]] || fail 'CLI lost remote failure status'
result=0
launch exec -c true > "$FIXTURE/output" 2> "$FIXTURE/error" || result=$?
[[ "$result" = 127 ]] || fail 'command was interpreted as an exec builtin option'
for arguments in none delimiter empty; do
    argv=()
    case "$arguments" in delimiter) argv=(--);; empty) argv=('');; esac
    result=0
    launch exec "${argv[@]}" > "$FIXTURE/output" 2> "$FIXTURE/error" || result=$?
    [[ "$result" = 2 ]] || fail 'missing command accepted'
done
# Decoder corruption, missing delimiter, empty command, extra frames, and limit.
for frame in '' '!' Y2F0 Y2F0AA Y2F0AA==junk AA==; do
    if bash "$CONVERGENCE_EXEC_HELPER" "$frame" < /dev/null > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail "accepted frame $frame"; fi
    [[ -z $(find "$TMPDIR" -type f -print) ]] || fail 'decoder leaked temporary data'
done
if bash "$CONVERGENCE_EXEC_HELPER" Y2F0AA== Y2F0AA== > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'multiple frames accepted'; fi
# Exactly 49152 encoded bytes: true + NUL + 36858-byte argument + NUL.
printf -v large '%*s' 36858 ''
launch exec true "$large"
if launch exec true "${large}x" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'oversize frame accepted'; fi
grep -Fxq 'Error: argument list too long for jailbox exec' "$FIXTURE/error"
# Call the decoder directly so the host cannot hide a divergent decoder cap.
frame=$(printf '%s\0' true "$large" | base64 | tr -d '\n')
[[ ${#frame} = 49152 ]] || fail 'wrong decoder boundary fixture'
bash "$CONVERGENCE_EXEC_HELPER" "$frame"
frame=$(printf '%s\0' true "${large}x" | base64 | tr -d '\n')
if bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'decoder accepted oversize frame'; fi
grep -Fxq 'Error: invalid jailbox exec frame' "$FIXTURE/error"
# The exec handler replaces itself with SSH, so local interruption need not
# wait for an extra supervising shell. Job control gives the child normal INT
# disposition instead of Bash's asynchronous-job ignored INT disposition.
(
    set -m
    export CONVERGENCE_EXEC_WAIT="$FIXTURE/ssh-pid"
    launch exec true > "$FIXTURE/signal-output" 2> "$FIXTURE/signal-error" & child=$!
    trap 'kill -TERM "$child" 2>/dev/null || true' EXIT
    for ((attempt=0; attempt<200; attempt++)); do
        [[ ! -s "$CONVERGENCE_EXEC_WAIT" ]] || break
        "$CONVERGENCE_REAL_SLEEP" 0.05
    done
    [[ -s "$CONVERGENCE_EXEC_WAIT" ]] || fail 'SSH signal fixture did not start'
    kill -INT "$(cat "$CONVERGENCE_EXEC_WAIT")"
    result=0
    wait "$child" || result=$?
    [[ "$result" = 130 ]] || fail "local SSH interrupt returned $result"
    trap - EXIT
)
# Independent callers traverse the whole validator with independent input.
before=$(snapshot)
launch exec cat < "$FIXTURE/input" > "$FIXTURE/one" & first=$!
launch exec cat < "$FIXTURE/expected" > "$FIXTURE/two" & second=$!
wait "$first"
wait "$second"
cmp "$FIXTURE/input" "$FIXTURE/one"
cmp "$FIXTURE/expected" "$FIXTURE/two"
[[ "$before" = "$(snapshot)" ]] || fail 'concurrent attaches mutated state'
[[ -z $(find "$TMPDIR" -type f -print) ]] || fail 'successful decoder leaked data'
printf 'PASS: exec argv, stdin, framing, limits, statuses, concurrency, and cleanup\n'

# Pre-exec failures must clean decoded bytes and must never run the command.
frame=$(printf '%s\0' printf executed | base64 | tr -d '\n')
if CONVERGENCE_ENGINE="$FIXTURE/missing-directory" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'missing working directory accepted'; fi
[[ ! -s "$FIXTURE/output" && -z $(find "$TMPDIR" -type f -print) ]] || fail 'cd failure executed or leaked data'
mkdir "$FIXTURE/decoder-tools"
export EXEC_REAL_MKTEMP EXEC_REAL_RM
EXEC_REAL_MKTEMP=$(command -v mktemp)
EXEC_REAL_RM=$(command -v rm)
cp "$ROOT/tests/fixtures/exec/mktemp.sh" "$FIXTURE/decoder-tools/mktemp"
cp "$ROOT/tests/fixtures/exec/rm.sh" "$FIXTURE/decoder-tools/rm"
chmod 755 "$FIXTURE/decoder-tools/"*
PATH="$FIXTURE/decoder-tools:$PATH" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output"
[[ $(cat "$FIXTURE/output") = executed ]] || fail 'secure decoder allocation failed'
if PATH="$FIXTURE/decoder-tools:$PATH" EXEC_FAIL_TEMP=true bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'mktemp failure accepted'; fi
[[ ! -s "$FIXTURE/output" ]] || fail 'command ran after mktemp failure'
for signal in HUP INT TERM; do
    if PATH="$FIXTURE/decoder-tools:$PATH" EXEC_INTERRUPT_TEMP="$signal" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'allocation interruption accepted'; fi
    [[ ! -s "$FIXTURE/output" && -z $(find "$TMPDIR" -type f -print) ]] || fail 'allocation interruption executed or leaked data'
done
if PATH="$FIXTURE/decoder-tools:$PATH" EXEC_FAIL_CLEANUP=true bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'cleanup failure accepted'; fi
[[ ! -s "$FIXTURE/output" ]] || fail 'command ran after cleanup failure'
# Injected deletion failure intentionally leaves the fixture file for its owner.
find "$TMPDIR" -type f -exec rm -f {} +
printf 'PASS: decoder allocation, cleanup, and directory failures stop execution\n'
# A decoder producer can publish complete-looking bytes and still fail.
cp "$ROOT/tests/fixtures/exec/base64.sh" "$FIXTURE/decoder-tools/base64"
chmod 755 "$FIXTURE/decoder-tools/base64"
for interrupt in false true; do
    if PATH="$FIXTURE/decoder-tools:$PATH" EXEC_INTERRUPT_DECODE="$interrupt" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then fail 'failed/interrupted decoder accepted'; fi
    [[ ! -s "$FIXTURE/output" && -z $(find "$TMPDIR" -type f -print) ]] || fail 'failed/interrupted decoder executed or leaked data'
done
printf 'PASS: decoder producer failure and interruption preserve cleanup\n'
