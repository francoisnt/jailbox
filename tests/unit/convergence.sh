#!/bin/bash
# Public CLI convergence against a deterministic engine/transport model. Real
# keys exercise generation validation; runtime tests own actual engine evidence.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FIXTURE=$(mktemp -d)
# macOS temporary paths can traverse /var, a symlink rejected for SSH state.
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/project" "$FIXTURE/engine"
export CONVERGENCE_ENGINE="$FIXTURE/engine" CONVERGENCE_LOG="$FIXTURE/actions"
export XDG_STATE_HOME="$FIXTURE/state"
export CONVERGENCE_IMAGE=1111111111111111111111111111111111111111111111111111111111111111
export CONVERGENCE_PROXY_IMAGE=2222222222222222222222222222222222222222222222222222222222222222
export JAILBOX_CONFIG_DEV_IMAGE=localhost/convergence
export PATH="$FIXTURE/bin:$PATH"
cat > "$FIXTURE/bin/podman" <<'ENGINE'
#!/bin/bash
set -euo pipefail
state=$CONVERGENCE_ENGINE
log=$CONVERGENCE_LOG
kind=${1:-}; action=${2:-}; name=${3:-}
file="$state/$kind.$name"
case "$kind $action" in
    'image exists') [[ ${CONVERGENCE_IMAGE_MISSING:-false} != true ]] ;;
    'container exists'|'network exists'|'volume exists') [[ -f "$file" ]] ;;
    'container inspect'|'network inspect'|'volume inspect')
        [[ -f "$file" ]] || exit 125
        template=${5:-}
        if [[ ${CONVERGENCE_INSPECT_ERROR:-} == "$kind" ]]; then exit 125; fi
        case "$template" in
            *jailbox.config-digest*) cat "$file" ;;
            *jailbox.ephemeral-home*) cat "$file" ;;
            '{{.State.Status}}') cat "$file.status" ;;
            '{{.Id}}') cat "$file.id" ;;
            '{{.Created.UnixNano}}') echo 1770000000000000000 ;;
            '{{.Image}}') cat "$file.image" ;;
            '{{.Driver}}') echo bridge ;;
            '{{.Internal}}') [[ "$name" == *-internal ]] && echo true || echo false ;;
            '{{.ID}}') printf '%064d\n' 3 ;;
            *'{{.NetworkID}}'*) printf '%064d\n' 3 ;;
            '{{(index .Subnets 0).Subnet}}'|'{{ (index .Subnets 0).Subnet }}') echo 10.240.57.0/24 ;;
            '{{.Mountpoint}}') echo "$state/home" ;;
            *'.Gateway'*) echo 10.89.0.1 ;;
            *'unsafe authentication'* ) exit 125 ;;
            *'overlay'* ) echo ok ;;
            *)
                if [[ -n ${CONVERGENCE_BAD_PROPERTY:-} && "$template" == *"$CONVERGENCE_BAD_PROPERTY"* ]]; then
                    echo false
                else
                    echo true
                fi
                ;;
        esac
        ;;
    'image inspect')
        if [[ "$name" == *-proxy ]]; then echo "$CONVERGENCE_PROXY_IMAGE"; else echo "$CONVERGENCE_IMAGE"; fi
        ;;
    'network create'|'volume create')
        printf '%s\n' "$*" >> "$log"
        label=""
        while (($#)); do
            case "$1" in --label) label=${2#*=}; shift ;; esac
            name=$1; shift
        done
        echo "$label" > "$state/$kind.$name"
        mkdir -p "$state/home"
        ;;
    'network rm'|'volume rm'|'image rm')
        printf '%s\n' "$*" >> "$log"
        rm -f "$file"
        ;;
    *)
        case "$kind" in
            ps) : ;;
            build) printf 'build %s\n' "$*" >> "$log" ;;
            pull) printf 'pull %s\n' "$action" >> "$log" ;;
            unshare) : ;;
            run)
                if [[ "$*" == *--rm* ]]; then
                    printf 'probe\n' >> "$log"
                    [[ "$*" != *'for pm in'* ]] || echo apt-get
                    exit 0
                fi
                printf 'run %s\n' "$*" >> "$log"
                label=""; receipt=""; name=""
                while (($#)); do
                    case "$1" in
                        --name) name=$2; shift ;;
                        --label) label=${2#*=}; shift ;;
                        --cidfile) receipt=$2; shift ;;
                    esac
                    shift
                done
                file="$state/container.$name"
                echo "$label" > "$file"
                echo running > "$file.status"
                printf '%064d\n' 4 > "$file.id"
                image=$CONVERGENCE_IMAGE
                [[ "$name" != *-proxy ]] || image=$CONVERGENCE_PROXY_IMAGE
                echo "$image" > "$file.image"
                if [[ -n "$receipt" ]]; then
                    cp "$file.id" "$receipt"
                    # Model a safe engine receipt independently of the caller's
                    # umask; cp otherwise inherits the fixture's writable mode.
                    chmod 600 "$receipt"
                fi
                [[ ${CONVERGENCE_FAIL_CREATE:-} != "$name" ]]
                ;;
            start)
                printf 'start %s\n' "$action" >> "$log"
                [[ ${CONVERGENCE_FAIL_START:-} != "$action" ]] || exit 125
                echo running > "$state/container.$action.status"
                ;;
            stop)
                printf 'stop %s\n' "$action" >> "$log"
                echo exited > "$state/container.$action.status"
                ;;
            rm)
                name=${!#}
                printf 'rm %s\n' "$name" >> "$log"
                [[ ${CONVERGENCE_FAIL_REMOVE:-} != "$name" ]] || exit 125
                rm -f "$state/container.$name" "$state/container.$name."*
                ;;
            exec)
                [[ ${CONVERGENCE_PROXY_FAILURE:-} != true ]] || exit 125
                printf 'HTTP/1.0 403 Forbidden\r\n\r\n'
                ;;
            *) echo "unexpected engine operation: $*" >&2; exit 125 ;;
        esac
        ;;
esac
ENGINE
cat > "$FIXTURE/bin/ssh" <<'SSH'
#!/bin/bash
set -euo pipefail
command=${!#}
if [[ ${CONVERGENCE_SSH_FAILURE:-} == true ]]; then exit 255; fi
if [[ ${CONVERGENCE_UPSTREAM_FAILURE:-} == true && "$command" == *https://example.com/* ]]; then exit 6; fi
if [[ ${CONVERGENCE_DENIAL_TRANSPORT_FAILURE:-} == true && "$command" == *--write-out* ]]; then exit 6; fi
if [[ -n ${CONVERGENCE_CONNECT_FAILURES:-} && "$command" == *--write-out* ]]; then
    printf 'proxy-connect\n' >> "$CONVERGENCE_LOG"
    attempts=$(grep -c '^proxy-connect$' "$CONVERGENCE_LOG")
    if ((attempts <= CONVERGENCE_CONNECT_FAILURES)); then exit 28; fi
fi
case "$command" in
    *'--write-out'*) printf '%s' "${CONVERGENCE_DENIAL_CODE:-403}" ;;
    *'jailbox-manage-proxy enable'*|*'jailbox-manage-proxy disable'*) echo sync >> "$CONVERGENCE_LOG" ;;
    *'sh -s'*) cat >/dev/null ;;
esac
SSH
# Avoid thirty seconds of readiness retries in deliberately failed starts.
cat > "$FIXTURE/bin/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
chmod +x "$FIXTURE/bin/"*
# shellcheck source=host/project-id.sh
source "$ROOT/host/project-id.sh"
PREFIX=$(jailbox_resource_prefix_for_path "$FIXTURE/project")
HASH=$(jailbox_project_hash_for_path "$FIXTURE/project")
GENERATION="$XDG_STATE_HOME/jailbox/projects/$HASH/ssh-generation"

launch() { (cd "$FIXTURE/project" && "$ROOT/jailbox" "$@"); }
expect_success() {
    if ! launch up > "$FIXTURE/output" 2>&1; then cat "$FIXTURE/output"; exit 1; fi
}
expect_failure() {
    if launch up > "$FIXTURE/output" 2>&1; then echo 'unexpected convergence success'; exit 1; fi
    grep -q "$1" "$FIXTURE/output" || { cat "$FIXTURE/output"; exit 1; }
}
snapshot() {
    find "$CONVERGENCE_ENGINE" "$XDG_STATE_HOME" -type f -exec cksum {} + | LC_ALL=C sort
}
assert_no_mutation() {
    [[ "$before" == "$(snapshot)" ]]
    if grep -Eq '^(run|start|stop|rm|sync|network create|volume create)' "$CONVERGENCE_LOG"; then
        echo 'refusal mutated state'; cat "$CONVERGENCE_LOG"; exit 1
    fi
}

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
CONVERGENCE_SSH_FAILURE=true expect_failure 'SSH authentication'
grep -q 'refusing sandbox reuse' "$FIXTURE/output"
assert_no_mutation

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
assert_no_mutation
before=$(snapshot); : > "$CONVERGENCE_LOG"
CONVERGENCE_INSPECT_ERROR=volume expect_failure 'could not inspect retention'
assert_no_mutation
if grep -q 'jailbox --clean' "$FIXTURE/output"; then exit 1; fi
launch --clean >/dev/null

# Egress creation uses the actual fallback subnet before rendering SSH config.
export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
expect_success
grep -q 'http://10.240.57.2:8888' "$GENERATION/ssh_config"
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
