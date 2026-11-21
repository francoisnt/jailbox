#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export CONVERGENCE_REAL_SLEEP
CONVERGENCE_REAL_SLEEP=$(command -v sleep)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
write_convergence_exec_helper
export CONVERGENCE_DRAIN_STDIN=true
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
# shellcheck source=src/host/core/resources/ssh.sh
source "$ROOT/src/host/core/resources/ssh.sh"
# shellcheck source=src/host/core/configuration/helpers.sh
source "$ROOT/src/host/core/configuration/helpers.sh"
# shellcheck source=src/host/core/configuration/version.sh
source "$ROOT/src/host/core/configuration/version.sh"
REMOTE_PATH=/home/jailbox/project
SCRIPT_DIR="$ROOT/src"
transport_exec() (
    load_environment_config() { return 0; }
    validate_attachment() { SSH_CONFIG=$GENERATION/ssh_config; CONTAINER_NAME=$PREFIX; }
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
# shellcheck disable=SC2016 # The remote shell signals itself.
transport_exec bash -c 'kill -s PIPE "$$"; exit 42' > "$FIXTURE/output" 2> "$FIXTURE/error" || result=$?
[[ "$result" = 141 ]] || fail 'exec lost the command default SIGPIPE disposition'
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
truncated=$(printf 'printf\0should-not-run' | base64)
for frame in '' '!' Y2F0 Y2F0AA Y2F0AA==junk AA== "$truncated"; do
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

# The shared decoder retains Bash command lookup without using temporary files.
printf '%s\n' 'printf "text script executed"' > "$CONVERGENCE_ENGINE/no-shebang"
chmod 755 "$CONVERGENCE_ENGINE/no-shebang"
frame=$(printf './no-shebang\0' | base64)
TMPDIR="$FIXTURE/missing-tmpdir" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output"
[[ $(cat "$FIXTURE/output") = 'text script executed' ]] || fail 'decoder lost Bash text-file lookup'
if CONVERGENCE_EXEC_PROJECT="$FIXTURE/missing-directory" bash "$CONVERGENCE_EXEC_HELPER" "$frame" > "$FIXTURE/output" 2> "$FIXTURE/error"; then
    fail 'missing working directory accepted'
fi
[[ ! -s "$FIXTURE/output" ]] || fail 'command ran after cd failure'

# Even a complete-looking encoded frame cannot mask producer failure.
mkdir -p "$FIXTURE/encoder-tools/libexec"
cp "$ROOT/tests/fixtures/exec/encoder.sh" "$FIXTURE/encoder-tools/libexec/jailbox-core"
chmod 755 "$FIXTURE/encoder-tools/libexec/jailbox-core"
for interrupt in false true; do
    if SCRIPT_DIR="$FIXTURE/encoder-tools" EXEC_INTERRUPT_ENCODE="$interrupt" transport_exec printf should-not-run > "$FIXTURE/output" 2> "$FIXTURE/error"; then
        fail 'failed/interrupted encoder accepted'
    fi
    [[ ! -s "$FIXTURE/output" ]] || fail 'command ran after encoding failure'
done
printf 'PASS: shared codec preserves lookup and stops on producer or directory failure\n'

# Missing or stale programs fail before SSH.
if SCRIPT_DIR="$FIXTURE/project" transport_exec true > "$FIXTURE/out" 2> "$FIXTURE/err"; then fail 'missing encoder accepted'; fi
grep -Fq 'jailbox helper is missing' "$FIXTURE/err"
ln -s "$ROOT/src/libexec" "$FIXTURE/project/libexec"
printf '9.9.9\n' > "$FIXTURE/project/VERSION"
if SCRIPT_DIR="$FIXTURE/project" transport_exec true > "$FIXTURE/out" 2> "$FIXTURE/err"; then fail 'stale encoder accepted'; fi
grep -Fq 'jailbox helper version mismatch' "$FIXTURE/err"
if "$CONVERGENCE_CONTAINER_PROGRAM" 9.9.9 exec "$FIXTURE/project" cHdkAA== > "$FIXTURE/out" 2> "$FIXTURE/err"; then fail 'stale decoder accepted'; fi
[[ ! -s "$FIXTURE/out" ]]
grep -Fq 'jailbox helper version mismatch' "$FIXTURE/err"
