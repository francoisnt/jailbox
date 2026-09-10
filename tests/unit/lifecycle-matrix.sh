#!/bin/bash
# Exercise the external fault mechanism with real filesystem mutations. A
# broken injector must fail portable CI rather than silently weaken runtime.
set -Eeuo pipefail
TEST_CASE=setup
trap 'printf "FAIL [%s] line %s: %s\n" "$TEST_CASE" "$LINENO" "$BASH_COMMAND" >&2' ERR
pass() { printf 'PASS: %s\n' "$TEST_CASE"; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/real" "$FIXTURE/state"
export XDG_STATE_HOME="$FIXTURE/state" LIFECYCLE_REAL_BIN="$FIXTURE/real"
export LIFECYCLE_EVENTS="$FIXTURE/events" LIFECYCLE_FAULT_AT=1
ln -s "$(command -v mkdir)" "$FIXTURE/real/mkdir"
ln -s "$ROOT/tests/lib/lifecycle-fault.sh" "$FIXTURE/bin/mkdir"
ln -s "$(command -v mktemp)" "$FIXTURE/real/mktemp"
ln -s "$ROOT/tests/lib/lifecycle-fault.sh" "$FIXTURE/bin/mktemp"
for mode in before after; do
    TEST_CASE="mkdir failure $mode mutation"
    export LIFECYCLE_FAULT_MODE="$mode"
    : > "$LIFECYCLE_EVENTS"
    result=0
    "$FIXTURE/bin/mkdir" "$XDG_STATE_HOME/space and ' quote" || result=$?
    [[ "$result" = 125 ]]
    if [[ "$mode" = before ]]; then
        [[ ! -d "$XDG_STATE_HOME/space and ' quote" ]]
    else
        [[ -d "$XDG_STATE_HOME/space and ' quote" ]]
    fi
    [[ $(wc -l < "$LIFECYCLE_EVENTS") -eq 1 ]]
    pass
done
# An unrelated path must never be intercepted, even with a selected fault.
: > "$LIFECYCLE_EVENTS"
TEST_CASE='unrelated paths pass through'
"$FIXTURE/bin/mkdir" "$FIXTURE/unrelated"
[[ -d "$FIXTURE/unrelated" && ! -s "$LIFECYCLE_EVENTS" ]]
pass

export LIFECYCLE_FAULT_MODE=barrier
TEST_CASE='mkdir barrier follows real mutation'
export LIFECYCLE_READY="$FIXTURE/ready" LIFECYCLE_RELEASE="$FIXTURE/release"
mkfifo "$LIFECYCLE_READY" "$LIFECYCLE_RELEASE"
exec {ready}<> "$LIFECYCLE_READY"
exec {release}<> "$LIFECYCLE_RELEASE"
"$FIXTURE/bin/mkdir" "$XDG_STATE_HOME/barrier" &
worker=$!
trap 'kill "$worker" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT
IFS= read -r -t 5 token <&"$ready"
[[ "$token" = ready && -d "$XDG_STATE_HOME/barrier" ]]
kill -0 "$worker" # The mutation has happened, but the wrapper is paused.
printf 'release\n' >&"$release"
result=0
wait "$worker" || result=$?
[[ "$result" = 125 ]]
trap 'rm -rf "$FIXTURE"' EXIT
exec {ready}>&-
exec {release}>&-
pass

TEST_CASE='staging allocation failure before creation'
export LIFECYCLE_FAULT_MODE=before
: > "$LIFECYCLE_EVENTS"
result=0
"$FIXTURE/bin/mktemp" -d "$XDG_STATE_HOME/.ssh-generation.XXXXXXXX" > "$FIXTURE/allocation" || result=$?
[[ "$result" = 125 && ! -s "$FIXTURE/allocation" ]]
if compgen -G "$XDG_STATE_HOME/.ssh-generation.*" >/dev/null; then echo "FAIL: $TEST_CASE" >&2; exit 1; fi
pass

TEST_CASE='staging allocation has its own interruption barrier'
export LIFECYCLE_FAULT_MODE=barrier
: > "$LIFECYCLE_EVENTS"
exec {ready}<> "$LIFECYCLE_READY"
exec {release}<> "$LIFECYCLE_RELEASE"
"$FIXTURE/bin/mktemp" -d "$XDG_STATE_HOME/.ssh-generation.XXXXXXXX" > "$FIXTURE/allocation" &
worker=$!
trap 'kill "$worker" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT
IFS= read -r -t 5 token <&"$ready"
allocated=$(cat "$FIXTURE/allocation")
[[ "$token" = ready && -d "$allocated" && ! -e "$allocated/server" ]]
printf 'release\n' >&"$release"
result=0
wait "$worker" || result=$?
[[ "$result" = 125 ]]
trap 'rm -rf "$FIXTURE"' EXIT
exec {ready}>&-
exec {release}>&-
pass

TEST_CASE='failed removal is logged without reaching the engine'
unset LIFECYCLE_FAULT_MODE LIFECYCLE_FAULT_AT
export LIFECYCLE_BACKEND_LOG="$FIXTURE/backend"
cat > "$FIXTURE/real/podman" <<'ENGINE'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$LIFECYCLE_BACKEND_LOG"
ENGINE
chmod 755 "$FIXTURE/real/podman"
ln -s "$ROOT/tests/lib/lifecycle-fault.sh" "$FIXTURE/bin/podman"
: > "$LIFECYCLE_EVENTS"
: > "$LIFECYCLE_BACKEND_LOG"
export LIFECYCLE_FAIL_REMOVE=true
result=0
"$FIXTURE/bin/podman" rm -f fixture-dev || result=$?
[[ "$result" = 125 && ! -s "$LIFECYCLE_BACKEND_LOG" ]]
grep -Fxq 'podman rm -f fixture-dev' "$LIFECYCLE_EVENTS"
unset LIFECYCLE_FAIL_REMOVE
pass

TEST_CASE='retention inspection failure leaves existence and other reads working'
export LIFECYCLE_FAIL_HOME_INSPECT=fixture-home
: > "$LIFECYCLE_EVENTS"
result=0
"$FIXTURE/bin/podman" volume inspect fixture-home --format 'jailbox.ephemeral-home' || result=$?
[[ "$result" = 125 && ! -s "$LIFECYCLE_BACKEND_LOG" && ! -s "$LIFECYCLE_EVENTS" ]]
"$FIXTURE/bin/podman" volume exists fixture-home
"$FIXTURE/bin/podman" volume inspect fixture-home --format '{{.Mountpoint}}'
"$FIXTURE/bin/podman" volume inspect different-home --format 'jailbox.ephemeral-home'
[[ $(wc -l < "$LIFECYCLE_BACKEND_LOG") -eq 3 ]]
unset LIFECYCLE_FAIL_HOME_INSPECT
pass

# shellcheck source=tests/lib/lifecycle-assertions.sh
source "$ROOT/tests/lib/lifecycle-assertions.sh"
TEST_CASE='fault identities tolerate allocation suffixes but reject operation drift'
printf '%s\n' 'mkdir /state/.ssh-generation.ABC123/server' > "$FIXTURE/reference"
printf '%s\n' 'mkdir /state/.ssh-generation.DEF456/server' > "$FIXTURE/actual"
lifecycle_same_fault_event "$FIXTURE/reference" "$FIXTURE/actual" 1
printf '%s\n' 'rm /state/.ssh-generation.DEF456/server' > "$FIXTURE/actual"
if lifecycle_same_fault_event "$FIXTURE/reference" "$FIXTURE/actual" 1; then echo "FAIL: $TEST_CASE" >&2; exit 1; fi
printf '%s\n' 'mkdir /state/.ssh-generation.DEF456/other' > "$FIXTURE/actual"
if lifecycle_same_fault_event "$FIXTURE/reference" "$FIXTURE/actual" 1; then echo "FAIL: $TEST_CASE" >&2; exit 1; fi
pass

TEST_CASE='state diagnostics accept rewording and reject unrelated records'
printf '%s\n' 'fixture-dev remains running (cleanup incomplete)' > "$FIXTURE/diagnosis"
lifecycle_reports_state "$FIXTURE/diagnosis" fixture-dev running
printf '%s\n' 'fixture-dev: stopped' 'fixture-dev-proxy: running' > "$FIXTURE/diagnosis"
if lifecycle_reports_state "$FIXTURE/diagnosis" fixture-dev running; then echo "FAIL: $TEST_CASE" >&2; exit 1; fi
pass

# The catalog is consumed by multiple later interfaces. Reject malformed or
# duplicate keys and inconsistent policy/recovery combinations at the boundary.
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
TEST_CASE='stdin-consuming child cannot drain the case catalog'
consume_row_stdin() {
    local IFS='|'
    cat >> "$FIXTURE/consumed-input"
    printf '%s\n' "$*" >> "$FIXTURE/visited-rows"
}
printf 'caller input\n' > "$FIXTURE/caller-input"
lifecycle_matrix_rows > "$FIXTURE/expected-rows"
lifecycle_each_row consume_row_stdin < "$FIXTURE/caller-input"
cmp "$FIXTURE/caller-input" "$FIXTURE/consumed-input"
cmp "$FIXTURE/expected-rows" "$FIXTURE/visited-rows"
pass

declare -A seen=()
while IFS='|' read -r key mode policy requested up status diagnosis attachment recovery retained stopped extra; do
    TEST_CASE="catalog row $key"
    [[ "$key" =~ ^[a-z][a-z0-9-]*$ && -z "$extra" ]]
    [[ -z ${seen[$key]-} ]]
    seen[$key]=true
    [[ "$mode" = plain || "$mode" = egress ]]
    [[ "$requested" = true || "$requested" = false ]]
    [[ "$policy" =~ ^(none|legacy|false|true|empty|corrupt|newline)$ ]]
    [[ "$up" = success || "$up" = refuse ]]
    [[ "$status" =~ ^(absent|running|stopped)$ && -n "$diagnosis" ]]
    [[ "$attachment" = allow || "$attachment" = refuse ]]
    [[ "$recovery" =~ ^(none|stop|clean)$ ]]
    [[ "$retained" =~ ^(new|keep|delete)$ ]]
    [[ "$stopped" = absent || "$stopped" = stopped ]]
    if [[ "$attachment" = allow ]]; then [[ "$status:$up" = running:success ]]; fi
    if [[ "$recovery" = clean ]]; then [[ "$retained" = delete ]]; fi
done < <(lifecycle_matrix_rows)
TEST_CASE='lifecycle catalog'
pass
