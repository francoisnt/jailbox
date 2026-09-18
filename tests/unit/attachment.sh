#!/bin/bash
# The complete attachment boundary against real credentials and a recorded
# engine/transport fixture. Production decisions do not define expectations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
export CONVERGENCE_SSH_LOG="$FIXTURE/ssh-calls"
ATTACH_PYTHON=$(command -v python3)
export CONVERGENCE_EXEC_HELPER="$FIXTURE/exec-helper"
sed "s|^cd /home/jailbox/project |cd \"\$CONVERGENCE_ENGINE\" |" "$ROOT/container/runtime/bin/jailbox-exec-argv" > "$CONVERGENCE_EXEC_HELPER"
printf 'attachment\0input\377\n' > "$FIXTURE/exec-input"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
observe() {
    local expected="$1" diagnostic="${2:-}" before result=0
    before=$(snapshot)
    : > "$CONVERGENCE_LOG"
    : > "$CONVERGENCE_SSH_LOG"
    launch connection-info > "$FIXTURE/records" 2> "$FIXTURE/diagnostic" || result=$?
    [[ "$before" = "$(snapshot)" && ! -s "$CONVERGENCE_LOG" ]] || fail 'attachment mutated resources, images, home, or credentials'
    if [[ "$expected" = allow ]]; then
        [[ "$result" = 0 ]] || { cat "$FIXTURE/diagnostic"; fail 'healthy attachment failed'; }
        printf 'ssh_config\t%s\0ssh_host\t%s\0remote_path\t%s\0project_id\t%s\0proxy_url\t%s\0' \
            "$GENERATION/ssh_config" "$PREFIX" /home/jailbox/project "$HASH" "$proxy" > "$FIXTURE/expected"
        cmp "$FIXTURE/expected" "$FIXTURE/records" || fail 'wrong connection bytes'
    else
        [[ "$result" != 0 && ! -s "$FIXTURE/records" ]] || fail 'refusal published connection records'
        grep -q "$diagnostic" "$FIXTURE/diagnostic" || { cat "$FIXTURE/diagnostic"; fail "missing diagnostic: $diagnostic"; }
    fi
    result=0
    CONVERGENCE_DRAIN_STDIN=true launch exec -- cat < "$FIXTURE/exec-input" > "$FIXTURE/exec-output" 2> "$FIXTURE/exec-diagnostic" || result=$?
    [[ "$before" = "$(snapshot)" && ! -s "$CONVERGENCE_LOG" ]] || fail 'exec mutated resources'
    if [[ "$expected" = allow ]]; then
        [[ "$result" = 0 ]] || fail 'exec attachment failed'
        cmp "$FIXTURE/exec-input" "$FIXTURE/exec-output" || fail 'exec attachment lost command input'
    else
        [[ "$result" != 0 && ! -s "$FIXTURE/exec-output" ]] || fail 'exec ran after attachment refusal'
        grep -q "$diagnostic" "$FIXTURE/exec-diagnostic" || fail 'exec lost refusal diagnostic'
    fi
    CONVERGENCE_DRAIN_STDIN=true "$ATTACH_PYTHON" "$ROOT/tests/lib/shell-terminal.py" \
        --cwd "$FIXTURE/project" --output "$FIXTURE/shell" --expect "$expected" -- "$ROOT/jailbox" shell || {
        cat "$FIXTURE/shell.stderr"; fail 'shell attachment decision failed';
    }
    [[ "$before" = "$(snapshot)" && ! -s "$CONVERGENCE_LOG" ]] || fail 'shell mutated resources'
    if [[ "$expected" = refuse ]]; then
        grep -q "$diagnostic" "$FIXTURE/shell.stderr" || fail 'shell lost refusal diagnostic'
    fi
}
check_foreign_network_member() {
    CONVERGENCE_FOREIGN_NETWORK="$1" observe refuse 'disconnect that container from this network before retrying'
    grep -Fq "network '$1' has unexpected container 'foreign-container'" "$FIXTURE/diagnostic" || fail 'foreign network member not identified'
    if grep -q 'jailbox stop\|jailbox --clean' "$FIXTURE/diagnostic"; then fail 'foreign network member recommends ineffective recovery'; fi
    [[ ! -s "$CONVERGENCE_SSH_LOG" ]] || fail 'transport preceded foreign member refusal'
}
mkdir -p "$XDG_STATE_HOME"
proxy=""
observe refuse 'jailbox up'
expect_success
observe allow
check_foreign_network_member "$PREFIX-net"
before=$(snapshot)
: > "$CONVERGENCE_LOG"
if launch --config jailbox.conf connection-info > "$FIXTURE/records" 2> "$FIXTURE/diagnostic"; then fail 'connection-info accepted --config'; fi
[[ ! -s "$FIXTURE/records" && ! -s "$CONVERGENCE_LOG" && "$before" = "$(snapshot)" ]] || fail '--config refusal published records or mutated state'
grep -q -- '--config cannot be used with connection-info' "$FIXTURE/diagnostic" || fail 'missing --config rejection diagnostic'
for property in ReadonlyRootfs EffectiveCaps SecurityOpt Privileged PortBindings Mounts; do
    CONVERGENCE_BAD_PROPERTY="$property" observe refuse 'jailbox stop'
done
for result in authorized-keys sockets hardening proxy-env direct-route mount:0; do
    CONVERGENCE_SESSION_RESULT="$result" observe refuse 'jailbox stop'
done
CONVERGENCE_SSH_FAILURE=true observe refuse 'SSH validation command failed'
CONVERGENCE_MANAGED_SETTINGS_FAILURE=true observe refuse 'jailbox up'
# Home policy precedence beats digest and SSH damage; inspection is not damage.
JAILBOX_CONFIG_EPHEMERAL_HOME=true observe refuse 'permanently deletes'
CONVERGENCE_INSPECT_ERROR=volume observe refuse 'could not inspect'
chmod 644 "$GENERATION/key"
observe refuse 'SSH generation'
chmod 600 "$GENERATION/key"
launch stop >/dev/null
observe refuse 'jailbox up'
expect_success
# A stopped generation resumes, including recorded ephemeral homes.
echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status"
observe refuse 'jailbox up'
expect_success
observe allow
# Every network role is checked, including one outside the requested mode.
printf '%064d\n' 0 > "$CONVERGENCE_ENGINE/network.$PREFIX-net-internal"
observe refuse 'configuration and jailbox version'
launch stop >/dev/null
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
proxy=http://10.240.57.2:8888
expect_success
observe allow
check_foreign_network_member "$PREFIX-net-internal"
check_foreign_network_member "$PREFIX-net-external"
CONVERGENCE_UPSTREAM_FAILURE=true observe allow
if grep -q 'https://example.com/' "$CONVERGENCE_SSH_LOG"; then fail 'attachment contacted the advisory upstream website'; fi
CONVERGENCE_PROXY_FAILURE=true observe refuse 'proxy'
CONVERGENCE_DENIAL_TRANSPORT_FAILURE=true observe refuse 'transport failed'
CONVERGENCE_DENIAL_CODE=200 observe refuse 'outside the allowlist'
CONVERGENCE_MANAGED_SETTINGS_FAILURE=true observe refuse 'jailbox up'
# A missing required proxy is resumable through up.
rm "$CONVERGENCE_ENGINE/container.$PREFIX-proxy"
observe refuse 'jailbox up'
launch stop >/dev/null
unset JAILBOX_CONFIG_EGRESS_ALLOW_0 JAILBOX_CONFIG_DEV_IMAGE
proxy=""
export JAILBOX_CONFIG_READONLY_PATHS=
# Both explicit and implicit vanished Containerfiles use attachment digest
# classification and refuse before any SSH or build, never launch discovery.
for selection in implicit explicit; do
    printf 'FROM debian\n' > "$FIXTURE/project/Containerfile"
    if [[ "$selection" = explicit ]]; then export JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile; fi
    expect_success
    rm "$FIXTURE/project/Containerfile"
    CONVERGENCE_SSH_FAILURE=true observe refuse 'configuration and jailbox version'
    [[ ! -s "$CONVERGENCE_SSH_LOG" ]] || fail "transport ran before digest refusal"
    if grep -q 'no Containerfile found\|configured Containerfile does not exist' "$FIXTURE/diagnostic"; then fail 'attachment used launch selector'; fi
    launch stop >/dev/null
    unset JAILBOX_CONFIG_DEV_CONTAINERFILE
done
export JAILBOX_CONFIG_DEV_IMAGE=localhost/convergence JAILBOX_CONFIG_DEV_CONTAINERFILE=missing
ln -s nowhere "$FIXTURE/project/Containerfile"
expect_success
observe allow
printf 'PASS: attachment schema, complete preflight, recovery, and non-mutation\n'

# Missing transport prerequisites are reported before engine discovery.
mkdir "$FIXTURE/no-keygen"
for tool in bash dirname basename realpath podman ssh; do
    ln -s "$(command -v "$tool")" "$FIXTURE/no-keygen/$tool"
done
: > "$CONVERGENCE_LOG"
if PATH="$FIXTURE/no-keygen" launch connection-info > "$FIXTURE/records" 2> "$FIXTURE/diagnostic"; then fail 'missing ssh-keygen accepted'; fi
grep -q 'required command not found: ssh-keygen' "$FIXTURE/diagnostic" || fail 'missing keygen not diagnosed'
[[ ! -s "$FIXTURE/records" && ! -s "$CONVERGENCE_LOG" ]]
# Invalid path bytes cannot become published metadata or generated SSH syntax.
for suffix in $'\t' $'\n'; do
    if XDG_STATE_HOME="$FIXTURE/$suffix" launch connection-info > "$FIXTURE/records" 2> "$FIXTURE/diagnostic"; then fail 'control character path accepted'; fi
    [[ ! -s "$FIXTURE/records" ]]
    grep -q 'ASCII control character' "$FIXTURE/diagnostic"
done
# Home retention diagnosis outranks simultaneous SSH and digest damage.
chmod 644 "$GENERATION/key"
JAILBOX_CONFIG_MEMORY_LIMIT=3g JAILBOX_CONFIG_EPHEMERAL_HOME=true observe refuse 'permanently deletes'
printf 'corrupt\n' > "$CONVERGENCE_ENGINE/volume.$PREFIX-home"
JAILBOX_CONFIG_MEMORY_LIMIT=3g observe refuse 'permanently deletes'
printf 'false\n' > "$CONVERGENCE_ENGINE/volume.$PREFIX-home"
chmod 600 "$GENERATION/key"
launch --clean >/dev/null
export JAILBOX_CONFIG_EPHEMERAL_HOME=true
expect_success
echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status"
observe refuse 'jailbox up'
if grep -q 'jailbox stop' "$FIXTURE/diagnostic"; then fail 'compatible stopped ephemeral generation requires stop'; fi
expect_success
observe allow
CONVERGENCE_SESSION_RESULT=project-write observe refuse 'correct host project ownership and permissions'
if grep -q 'jailbox stop\|jailbox --clean' "$FIXTURE/diagnostic"; then fail 'host permission failure recommends destructive recovery'; fi
# Missing local payloads require installation repair, not sandbox replacement.
if (
    source "$ROOT/host/common.sh"
    source "$ROOT/host/validation.sh"
    SCRIPT_DIR="$FIXTURE/missing-installation"
    UP_CONVERGING=false
    EFFECTIVE_READONLY_PATHS=()
    EGRESS_ALLOW=()
    validate_development_session full
) > "$FIXTURE/records" 2> "$FIXTURE/diagnostic"; then fail 'missing payload accepted'; fi
[[ ! -s "$FIXTURE/records" ]] || fail 'missing payload published success'
grep -q 'repair the jailbox installation' "$FIXTURE/diagnostic" || fail 'missing installation repair guidance'
if grep -q 'jailbox stop\|jailbox --clean' "$FIXTURE/diagnostic"; then fail 'missing payload recommends destructive recovery'; fi
printf 'PASS: attachment prerequisites, path syntax, and home-aware recovery precedence\n'

# Required readers may print plausible bytes and then fail. Their statuses,
# rather than downstream comparisons, must gate publication.
export ATTACH_REAL_CAT ATTACH_FAIL_READ
ATTACH_REAL_CAT=$(command -v cat)
cat > "$FIXTURE/bin/cat" <<'READER'
#!/bin/bash
"$ATTACH_REAL_CAT" "$@" || exit $?
if [[ ${1:-} = "${ATTACH_FAIL_READ:-}" && -n ${ATTACH_FAIL_READ:-} ]]; then exit 42; fi
READER
chmod 755 "$FIXTURE/bin/cat"
for ATTACH_FAIL_READ in "$GENERATION/server/ssh_host_ed25519_key.pub" "$GENERATION/container-id"; do
    observe refuse 'could not read'
done
unset ATTACH_FAIL_READ
launch stop >/dev/null
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
proxy=http://10.240.57.2:8888
expect_success
ATTACH_FAIL_READ="$ROOT/container/tinyproxy/tinyproxy.conf" observe refuse 'could not read or render'
printf 'PASS: failed required readers cannot publish plausible connection records\n'

observe allow
cp "$FIXTURE/records" "$FIXTURE/full-path-records"
mkdir "$FIXTURE/attach-only"
for tool in bash dirname basename realpath podman ssh ssh-keygen cat tr cut sed sort id stat wc tail cmp awk sha256sum shasum; do
    resolved=$(command -v "$tool") || continue
    ln -s "$resolved" "$FIXTURE/attach-only/$tool"
done
PATH="$FIXTURE/attach-only" launch connection-info > "$FIXTURE/records" 2> "$FIXTURE/diagnostic" || { cat "$FIXTURE/diagnostic"; fail 'attachment added a build or editor dependency'; }
cmp "$FIXTURE/full-path-records" "$FIXTURE/records"
printf 'PASS: healthy attachment needs no cksum, Base64, or editor\n'
PATH="$FIXTURE/attach-only" "$ATTACH_PYTHON" "$ROOT/tests/lib/shell-terminal.py" \
    --cwd "$FIXTURE/project" --output "$FIXTURE/shell-tools" -- "$ROOT/jailbox" shell || {
    cat "$FIXTURE/shell-tools.stderr"; fail 'shell added a build, encoding, or editor dependency';
}
for tool in base64 mktemp rm; do
    ln -s "$(command -v "$tool")" "$FIXTURE/attach-only/$tool"
done
PATH="$FIXTURE/attach-only" launch exec bash -c 'printf %s attached' > "$FIXTURE/exec-output" 2> "$FIXTURE/exec-diagnostic" || {
    cat "$FIXTURE/exec-diagnostic"; fail 'exec added a build or editor dependency'
}
[[ $(cat "$FIXTURE/exec-output") = attached ]] || fail 'exec without build tools lost output'
printf 'PASS: healthy exec needs no cksum or editor\n'
