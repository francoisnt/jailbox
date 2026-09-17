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
# shellcheck source=tests/lib/lifecycle-runtime-faults.sh
source "$ROOT/tests/lib/lifecycle-runtime-faults.sh"
TEST_CASE='unknown fault fixtures fail before constructing any state'
construct() { printf 'unexpected construction\n' > "$FIXTURE/constructed"; }
matrix_die() { printf '%s\n' "$*" >&2; exit 1; }
for command in up stop --clean unmapped; do
    if (fault_baseline "$command" unsupported) > "$FIXTURE/error" 2>&1; then
        exit 1
    fi
    grep -Fxq "No starting state defined for $command:unsupported" "$FIXTURE/error"
    [[ ! -e "$FIXTURE/constructed" ]]
done
unset -f construct matrix_die
pass

TEST_CASE='independent fault coverage rejects each missing operation'
# Deliberately authored fixtures, never generated from the coverage requirements.
# Paths, hashes and allocation suffixes are irrelevant to operation membership.
cat > "$FIXTURE/up-trace" <<'TRACE'
podman network create --internal jailbox-project-abc-net-internal
podman network create --label digest=abc jailbox-project-abc-net-external
mkdir -p -- /state/jailbox/projects/abc
mkdir -p /state/jailbox/projects/abc
mkdir -p /state/jailbox/projects/abc
mkdir -p -- /state/jailbox/projects/abc
chmod 644 /state/jailbox/projects/abc/tinyproxy-filter
chmod 644 /state/jailbox/projects/abc/tinyproxy.conf
podman run -d --name jailbox-project-abc-proxy --read-only
mktemp /state/jailbox/projects/abc/gitconfig.tmp.XXXXXX
chmod 600 /state/jailbox/projects/abc/gitconfig.tmp.random
mv /state/jailbox/projects/abc/gitconfig.tmp.random /state/jailbox/projects/abc/gitconfig
mktemp -d /state/jailbox/projects/abc/.ssh-generation.XXXXXXXX
mkdir /state/jailbox/projects/abc/.ssh-generation.random/server
ssh-keygen -t ed25519 -f /state/key -N '' -C jailbox-client -q
ssh-keygen -t ed25519 -f /state/server/key -N '' -C jailbox-server -q
cp /state/key.pub /state/server/authorized_keys
chmod 600 /state/key /state/server/authorized_keys
chmod 644 /state/key.pub /state/server/ssh_host_ed25519_key.pub
mv -- /state/.ssh-generation.random /state/ssh-generation
rm -rf -- /state/.ssh-generation.random
podman run -d --name jailbox-project-abc --cidfile /state/ssh-generation/container-id
ssh -F /state/config jailbox-project-abc jailbox-manage-proxy\ enable\ http://proxy
TRACE
cat > "$FIXTURE/cleanup-trace" <<'TRACE'
podman stop jailbox-project-abc
podman rm jailbox-project-abc
podman stop jailbox-project-abc-proxy
podman rm jailbox-project-abc-proxy
podman network rm jailbox-project-abc-net-internal
podman network rm jailbox-project-abc-net-external
TRACE
for scenario in up:false up:none up:new-ephemeral up:resume up:plain-network stop:false stop:true --clean:false --clean:true; do
    command=${scenario%:*}; policy=${scenario#*:}
    if [[ "$policy" = resume ]]; then
        printf '%s\n' 'podman start jailbox-project-abc-proxy' 'podman start jailbox-project-abc' > "$FIXTURE/coverage"
    elif [[ "$policy" = plain-network ]]; then
        printf '%s\n' 'podman network create --label digest=abc jailbox-project-abc-net' > "$FIXTURE/coverage"
    elif [[ "$command" = up ]]; then
        cp "$FIXTURE/up-trace" "$FIXTURE/coverage"
        if [[ "$policy" != false ]]; then
            printf '%s\n' 'podman volume create --label policy home' 'podman unshare chown 1000:1000 /volume' >> "$FIXTURE/coverage"
        fi
    else
        cp "$FIXTURE/cleanup-trace" "$FIXTURE/coverage"
        if [[ "$command" = --clean || "$policy" = true ]]; then
            printf '%s\n' 'podman volume rm jailbox-project-abc-home' >> "$FIXTURE/coverage"
        fi
        if [[ "$command" = --clean ]]; then
            printf '%s\n' 'podman image rm jailbox-project-abc-image' 'podman image rm jailbox-project-abc-proxy' \
                'rm -rf -- /state/jailbox/projects/abc' >> "$FIXTURE/coverage"
        else
            printf '%s\n' 'rm -rf -- /state/ssh-generation /state/key' >> "$FIXTURE/coverage"
        fi
    fi
    lifecycle_require_fault_coverage "$FIXTURE/coverage" "$command" "$policy"
    for ((point=1; point<=$(wc -l < "$FIXTURE/coverage"); point++)); do
        sed "${point}d" "$FIXTURE/coverage" > "$FIXTURE/reduced"
        # Preserve the total with an unrelated mutation: counts alone cannot pass.
        printf '%s\n' 'chmod 700 /unrelated' >> "$FIXTURE/reduced"
        if lifecycle_require_fault_coverage "$FIXTURE/reduced" "$command" "$policy" > "$FIXTURE/coverage-error" 2>&1; then
            printf 'FAIL: accepted missing %s operation %s\n' "$scenario" "$point" >&2; exit 1
        fi
        grep -q 'Missing fault coverage' "$FIXTURE/coverage-error"
    done
done
# Duplicating the proxy launch must not replace development-container coverage.
sed '/--cidfile/d' "$FIXTURE/up-trace" > "$FIXTURE/reduced"
printf '%s\n' 'podman run -d --name jailbox-project-abc-proxy --read-only' >> "$FIXTURE/reduced"
if lifecycle_require_fault_coverage "$FIXTURE/reduced" up false 2>/dev/null; then exit 1; fi
if lifecycle_require_fault_coverage "$FIXTURE/up-trace" up true 2>/dev/null; then exit 1; fi
cp "$FIXTURE/up-trace" "$FIXTURE/extended"
printf '%s\n' 'chmod 700 /additional-state' >> "$FIXTURE/extended"
lifecycle_require_fault_coverage "$FIXTURE/extended" up false
pass

TEST_CASE='runtime rejects reduced traces before publishing expected cases'
(
    # shellcheck source=tests/lib/lifecycle-runtime-faults.sh
    source "$ROOT/tests/lib/lifecycle-runtime-faults.sh"
    LOG="$FIXTURE/guard-log"
    mkdir "$LOG"
    matrix_case_begin() { CASE_KEY="$1"; }
    fault_baseline() { :; }
    expect_success() { printf '%s\n' 'mkdir /some-state' > "$LIFECYCLE_EVENTS"; }
    matrix_die() { exit 42; }
    matrix_case_pass() { touch "$LOG/passed"; }
    run_mutation_faults up false
) > "$FIXTURE/guard-error" 2>&1 && result=0 || result=$?
[[ "$result" = 42 && ! -e "$FIXTURE/guard-log/passed" && ! -e "$FIXTURE/guard-log/expected-faults" ]]
grep -q 'Missing fault coverage' "$FIXTURE/guard-error"
pass

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
while IFS='|' read -r key mode policy requested up status attachment recovery retained stopped extra; do
    TEST_CASE="catalog row $key"
    [[ "$key" =~ ^[a-z][a-z0-9-]*$ && -z "$extra" ]]
    [[ -z ${seen[$key]-} ]]
    seen[$key]=true
    [[ "$mode" = plain || "$mode" = egress ]]
    [[ "$requested" = true || "$requested" = false ]]
    [[ "$policy" =~ ^(none|legacy|false|true|empty|corrupt|newline)$ ]]
    [[ "$up" = success || "$up" = refuse ]]
    [[ "$status" =~ ^(absent|running|stopped)$ ]]
    [[ "$attachment" = allow || "$attachment" = refuse ]]
    [[ "$recovery" =~ ^(none|stop|clean)$ ]]
    [[ "$retained" =~ ^(new|keep|delete)$ ]]
    [[ "$stopped" = absent || "$stopped" = stopped ]]
    if [[ "$attachment" = allow ]]; then [[ "$status:$up" = running:success ]]; fi
    if [[ "$recovery" = clean ]]; then [[ "$retained" = delete ]]; fi
done < <(lifecycle_matrix_rows)
TEST_CASE='lifecycle catalog'
pass
