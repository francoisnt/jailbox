#!/bin/bash
# Public CLI convergence against a deterministic engine/transport model. Real
# keys exercise generation validation; runtime tests own actual engine evidence.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"

check_managed_settings_failure() {
    local before
    before=$(snapshot); : > "$CONVERGENCE_LOG"
    CONVERGENCE_MANAGED_SETTINGS_FAILURE=true expect_failure "$1"
    grep -q 'sandbox convergence failed' "$FIXTURE/output"
    grep -q '^sync$' "$CONVERGENCE_LOG"
    if grep -q 'jailbox --clean' "$FIXTURE/output"; then exit 1; fi
    [[ "$before" == "$(snapshot)" ]]
    if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then exit 1; fi
    # Once the injected check failure clears, another up synchronizes and
    # validates the same sandbox without replacing its resources or home.
    : > "$CONVERGENCE_LOG"
    expect_success
    grep -q '^sync$' "$CONVERGENCE_LOG"
    [[ "$before" == "$(snapshot)" ]]
    if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then exit 1; fi
    echo "PASS: $1 blocks readiness and permits retry without resource replacement"
}

# Failed identity conversion must stop the public CLI before engine work.
cat > "$FIXTURE/bin/tr" <<'TR'
#!/bin/bash
printf '%s' "${CONVERGENCE_PARTIAL:-}"
exit 42
TR
chmod 755 "$FIXTURE/bin/tr"
for partial in '' plausible; do
    : > "$CONVERGENCE_LOG"
    if CONVERGENCE_PARTIAL="$partial" launch up > "$FIXTURE/output" 2>&1; then exit 1; fi
    [[ ! -s "$CONVERGENCE_LOG" ]]
done
rm "$FIXTURE/bin/tr"

# A writer failure after allocation must stop launch and leave no staging file.
export CONVERGENCE_REAL_GIT
CONVERGENCE_REAL_GIT=$(command -v git)
cat > "$FIXTURE/bin/git" <<'GIT'
#!/bin/bash
if [[ " $* " == *' --file '* ]]; then exit 42; fi
exec "$CONVERGENCE_REAL_GIT" "$@"
GIT
chmod 755 "$FIXTURE/bin/git"
: > "$CONVERGENCE_LOG"
expect_failure "Run 'jailbox stop'"
if grep -Eq '^(run|volume create)' "$CONVERGENCE_LOG"; then exit 1; fi
[[ -z $(find "$XDG_STATE_HOME" -name 'gitconfig*') ]]
[[ -z $(find "$CONVERGENCE_ENGINE" -name 'network.*' -o -name 'container.*') ]]
rm "$FIXTURE/bin/git"

# The actual CLI must deliver helper failures to its rollback owner, including
# engine mutations that succeed before reporting an error.
for kind in network volume; do
    for phase in before after; do
        : > "$CONVERGENCE_LOG"
        CONVERGENCE_FAIL_MUTATION="$kind:$phase" expect_failure "Run 'jailbox stop'"
        if grep -Eq '^run ' "$CONVERGENCE_LOG" || grep -q 'SSH is up' "$FIXTURE/output"; then exit 1; fi
        [[ -z $(find "$CONVERGENCE_ENGINE" -name 'network.*' -o -name 'container.*') ]]
        [[ ! -e "$GENERATION" ]]
        # Reset this isolated fixture through public cleanup before the next case.
        launch --clean > /dev/null
    done
done
echo 'PASS: CLI mutation failures reach rollback without readiness success'

CONVERGENCE_IMAGE_MISSING=true expect_success
grep -q '^pull localhost/convergence$' "$CONVERGENCE_LOG"
[[ -f "$GENERATION/key" ]]
printf retained > "$CONVERGENCE_ENGINE/home/marker"
before=$(snapshot)
: > "$CONVERGENCE_LOG"
expect_success
[[ "$before" == "$(snapshot)" ]]
if grep -Eq '^(build|probe|run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: absent creation and running reuse preserve identities and home'

# Inspect through both callers in one shell with existing rollback inventory.
# The real detectors may refresh observations, but only a new launch may clear
# attempts. Use the existing engine fixture and real SSH material, not detector
# stubs, so the complete compatibility path is exercised conditionally too.
(
    # shellcheck source=tests/lib/core.sh
    source "$ROOT/tests/lib/core.sh" "$ROOT/src"
    PROJECT_DIR="$FIXTURE/project"
    prepare_launch
    initialize_runtime_ids
    LAUNCH_ATTEMPTED_RESOURCES=(network:attempted)
    LAUNCH_ATTEMPTED_HOST_PATHS=("$FIXTURE/attempted")
    for mode in launch attach; do
        if ! inspect_sandbox_compatibility "$mode"; then exit 1; fi
        [[ ${LAUNCH_ATTEMPTED_RESOURCES[*]} = network:attempted ]]
        [[ ${LAUNCH_ATTEMPTED_HOST_PATHS[*]} = "$FIXTURE/attempted" ]]
        [[ "$OBSERVED_DEV_STATE" = running && "$OBSERVED_PROXY_STATE" = absent ]]
        observed_resource_present "container:$PREFIX"
    done
    # Healthy reuse should start with fresh bookkeeping and record no creations.
    bring_up_sandbox > "$FIXTURE/reuse-state-output" 2>&1
    [[ -z ${LAUNCH_ATTEMPTED_RESOURCES[*]-} && -z ${LAUNCH_ATTEMPTED_HOST_PATHS[*]-} ]]
)
[[ "$before" == "$(snapshot)" ]]
if grep -Eq '^(build|probe|run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: compatibility inspection preserves attempts; launch owns their reset'

echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status"
keys=$(find "$GENERATION" -type f -exec cksum {} + | sort)
before=$(snapshot)
CONVERGENCE_FAIL_START=$PREFIX expect_failure 'could not start development container'
grep -q 'sandbox convergence failed' "$FIXTURE/output"
[[ "$before" == "$(snapshot)" ]]
expect_success
if grep -Eq '^(build|probe)' "$CONVERGENCE_LOG"; then exit 1; fi
[[ "$keys" == "$(find "$GENERATION" -type f -exec cksum {} + | sort)" ]]
[[ $(cat "$CONVERGENCE_ENGINE/home/marker") == retained ]]
echo 'PASS: stopped resume preserves generation and home'

# A recreated dependency remains incompatible until the advised stop/up cycle.
echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status"
touch "$CONVERGENCE_ENGINE/network.$PREFIX-net.recreated"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'network .* was recreated'
grep -q "jailbox stop.*jailbox up" "$FIXTURE/output"
grep -q 'preserves the persistent home' "$FIXTURE/output"
if grep -q 'jailbox --clean' "$FIXTURE/output"; then exit 1; fi
assert_no_mutation
launch stop > /dev/null
[[ -f "$CONVERGENCE_ENGINE/volume.$PREFIX-home" ]]
[[ $(cat "$CONVERGENCE_ENGINE/home/marker") == retained ]]
expect_success
if grep -q '^volume create' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: recreated network refusal names working stop/up recovery and persistent-home retention'

# Partial generation damage must identify the missing material and recover
# through regeneration, without silently repairing it during refusal.
rm "$GENERATION/known_hosts"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'SSH generation.*known_hosts'
grep -q "jailbox stop.*jailbox up" "$FIXTURE/output"
grep -q 'preserves the persistent home' "$FIXTURE/output"
if grep -q 'jailbox --clean' "$FIXTURE/output"; then exit 1; fi
assert_no_mutation
launch stop > /dev/null
[[ -f "$CONVERGENCE_ENGINE/volume.$PREFIX-home" ]]
expect_success
if grep -q '^volume create' "$CONVERGENCE_LOG"; then exit 1; fi
[[ -s "$GENERATION/known_hosts" && $(cat "$CONVERGENCE_ENGINE/home/marker") == retained ]]
echo 'PASS: partial SSH generation refusal names working recovery without deleting persistent home'

# A wrong-mode state directory survives stop: the message must name the manual
# prerequisite, and applying that correction must allow reuse without replacement.
chmod 755 "$(dirname "$GENERATION")"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'runtime directory.*mode 700'
grep -q 'correct its metadata' "$FIXTURE/output"
if grep -q 'jailbox --clean' "$FIXTURE/output"; then exit 1; fi
assert_no_mutation
chmod 700 "$(dirname "$GENERATION")"
: > "$CONVERGENCE_LOG"
expect_success
[[ "$before" == "$(snapshot)" ]]
if grep -Eq '^(run|start|stop|rm)' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: unsafe directory metadata names a manual correction that preserves the generation and home'

for property in ReadonlyRootfs SecurityOpt PortBindings Mounts NetworkSettings; do
    before=$(snapshot); : > "$CONVERGENCE_LOG"
    CONVERGENCE_BAD_PROPERTY=$property expect_failure 'incompatible\|unsafe authentication'
    assert_no_mutation
    echo "PASS: $property refusal preserves sandbox"
done
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_IMAGE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa expect_success
if grep -Eq '^(build|probe)' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: moved image tags do not trigger builds or refuse reuse'

before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_SSH_FAILURE=true expect_failure 'SSH validation command failed'
grep -q 'refusing sandbox reuse' "$FIXTURE/output"
assert_no_mutation

for result in authorized-keys sockets mount:0 hardening proxy-env direct-route malformed; do
    before=$(snapshot); : > "$CONVERGENCE_LOG"
    CONVERGENCE_SESSION_RESULT=$result expect_failure 'refusing sandbox reuse'
    assert_no_mutation
done
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_SESSION_RESULT=project-write expect_failure 'correct host project ownership and permissions'
if grep -q 'jailbox stop\|jailbox --clean' "$FIXTURE/output"; then
    echo 'host permission failure recommends destructive recovery'; exit 1
fi
assert_no_mutation
echo 'PASS: batched live validation failures preserve the sandbox'

check_managed_settings_failure 'stale managed downloader settings remain'

chmod 644 "$GENERATION/key"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'SSH generation'
assert_no_mutation
chmod 600 "$GENERATION/key"

# Stored home precedence resolves combined failures without proposing stop
# for a home that stop would preserve.
echo corrupt > "$CONVERGENCE_ENGINE/volume.$PREFIX-home"
echo malformed > "$CONVERGENCE_ENGINE/container.$PREFIX"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'permanently deletes'
grep -q 'corrupt retention metadata' "$FIXTURE/output"
grep -q 'jailbox --clean.*jailbox up' "$FIXTURE/output"
grep -q 'home and runtime state' "$FIXTURE/output"
if grep -q 'jailbox stop' "$FIXTURE/output"; then exit 1; fi
assert_no_mutation
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_INSPECT_ERROR=volume expect_failure 'could not inspect retention'
assert_no_mutation
if grep -Eq 'jailbox --clean|corrupt retention' "$FIXTURE/output"; then exit 1; fi
launch --clean >/dev/null

# Egress creation uses the actual fallback subnet before rendering SSH config.
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
expect_success
grep -q 'http://10.240.57.2:8888' "$GENERATION/ssh_config"
check_managed_settings_failure 'managed downloader settings are not synchronized'
for state in proxy_stopped dev_stopped proxy_missing; do
    case "$state" in
        proxy_stopped) echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX-proxy.status" ;;
        dev_stopped) echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status" ;;
        proxy_missing) rm "$CONVERGENCE_ENGINE/container.$PREFIX-proxy" ;;
    esac
    keys=$(find "$GENERATION" -type f -exec cksum {} + | sort)
    : > "$CONVERGENCE_LOG"
    if [[ "$state" = proxy_stopped || "$state" = proxy_missing ]]; then
        # Outlast the former six-attempt window, as a stale ARP entry can.
        CONVERGENCE_CONNECT_FAILURES=7 expect_success
        [[ $(grep -c '^proxy-connect$' "$CONVERGENCE_LOG") = 8 ]]
    else
        expect_success
    fi
    [[ "$keys" == "$(find "$GENERATION" -type f -exec cksum {} + | sort)" ]]
    if grep -Eq '^(stop|rm)' "$CONVERGENCE_LOG"; then exit 1; fi
    if [ "$state" = proxy_missing ]; then
        [[ $(grep -c '^build ' "$CONVERGENCE_LOG") = 1 ]]
        grep -q 'Containerfile.*tinyproxy\|tinyproxy.*Containerfile' "$CONVERGENCE_LOG"
    elif grep -Eq '^(build|probe)' "$CONVERGENCE_LOG"; then
        exit 1
    fi
    echo "PASS: egress $state converges without replacement"
done
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_CONNECT_FAILURES=2 expect_failure 'transport failed'
[[ $(grep -c '^proxy-connect$' "$CONVERGENCE_LOG") = 1 ]]
assert_no_mutation
rm "$CONVERGENCE_ENGINE/container.$PREFIX-proxy"
: > "$CONVERGENCE_LOG"
CONVERGENCE_CONNECT_FAILURES=99 expect_failure 'transport failed'
grep -q 'sandbox convergence failed' "$FIXTURE/output"
if grep -q 'refusing sandbox reuse' "$FIXTURE/output"; then exit 1; fi
[[ $(grep -c '^proxy-connect$' "$CONVERGENCE_LOG") = 16 ]]
[[ -f "$CONVERGENCE_ENGINE/container.$PREFIX-proxy" && -f "$GENERATION/key" ]]
echo 'PASS: dependency transport readiness retries are bounded; existing health failures refuse immediately'
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_PROXY_IMAGE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb expect_success
if grep -Eq '^(build|probe)' "$CONVERGENCE_LOG"; then exit 1; fi
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_DENIAL_CODE=502 expect_failure 'allowlist'
assert_no_mutation
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_DENIAL_TRANSPORT_FAILURE=true expect_failure 'transport failed'
assert_no_mutation
CONVERGENCE_UPSTREAM_FAILURE=true expect_success
grep -q 'Warning: upstream availability' "$FIXTURE/output"
echo 'PASS: DNS/transport failure is not denial; upstream outages are advisory'

# Orphans are never repaired, and explicit recovery preserves unrelated files.
printf keep > "$(dirname "$GENERATION")/unrelated"
rm "$CONVERGENCE_ENGINE/container.$PREFIX"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure orphaned
assert_no_mutation
launch stop >/dev/null
[[ $(cat "$(dirname "$GENERATION")/unrelated") == keep ]]
expect_success

# Failed resume does not stop the existing generation or delete its new proxy.
rm "$CONVERGENCE_ENGINE/container.$PREFIX-proxy"
echo exited > "$CONVERGENCE_ENGINE/container.$PREFIX.status"
: > "$CONVERGENCE_LOG"
CONVERGENCE_SSH_FAILURE=true expect_failure 'Retained container'
[[ -f "$CONVERGENCE_ENGINE/container.$PREFIX-proxy" && -f "$GENERATION/key" ]]
if grep -Eq '^(stop|rm)' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: failed resume retains new dependency and original generation'
launch stop >/dev/null
expect_success

# A surviving proxy does not depend on a failed new development generation.
rm "$CONVERGENCE_ENGINE/container.$PREFIX"
rm -rf "$GENERATION"
: > "$CONVERGENCE_LOG"
CONVERGENCE_FAIL_CREATE=$PREFIX expect_failure 'Retained container'
[[ ! -e "$GENERATION" && -f "$CONVERGENCE_ENGINE/container.$PREFIX-proxy" ]]
: > "$CONVERGENCE_LOG"
expect_success
[[ $(grep -c '^build ' "$CONVERGENCE_LOG") = 1 ]]
grep -q '^build .*Containerfile.wrapper' "$CONVERGENCE_LOG"

# Missing networks are not recreated underneath surviving containers.
rm "$CONVERGENCE_ENGINE/network.$PREFIX-net-internal"
before=$(snapshot); : > "$CONVERGENCE_LOG"
expect_failure 'network is missing'
assert_no_mutation
launch stop >/dev/null
expect_success

# Failure during first container creation: removal must precede credentials;
# failed removal retains both new proxy and generation for explicit recovery.
launch stop >/dev/null
: > "$CONVERGENCE_LOG"
CONVERGENCE_FAIL_CREATE=$PREFIX CONVERGENCE_FAIL_REMOVE=$PREFIX expect_failure 'cleanup could not remove'
[[ -f "$GENERATION/key" && -f "$CONVERGENCE_ENGINE/container.$PREFIX-proxy" ]]
if grep -q "rm $PREFIX-proxy" "$CONVERGENCE_LOG"; then exit 1; fi
launch stop >/dev/null
expect_success

launch stop >/dev/null
CONVERGENCE_BAD_PROPERTY=ReadonlyRootfs expect_failure 'sandbox convergence failed'
[[ ! -f "$CONVERGENCE_ENGINE/container.$PREFIX" && ! -e "$GENERATION" ]]
printf 'FROM localhost/convergence\n' > "$FIXTURE/project/Containerfile"
: > "$CONVERGENCE_LOG"
JAILBOX_CONFIG_DEV_IMAGE="" CONVERGENCE_IMAGE_MISSING=true expect_failure 'just-built development image'
if grep -q '^pull ' "$CONVERGENCE_LOG"; then exit 1; fi
echo 'PASS: new-container readiness errors report convergence failure; missing built images never pull'

echo 'Convergence tests passed'
