#!/bin/bash
# Shared deterministic engine/transport fixture; callers set ROOT.
# shellcheck disable=SC2034,SC2154 # Shared fixture exports state and consumes caller snapshots.
FIXTURE=$(mktemp -d)
# macOS temporary paths can traverse /var, a symlink rejected for SSH state.
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/project" "$FIXTURE/engine"
export GIT_CONFIG_GLOBAL="$FIXTURE/git-identity" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name 'Convergence Test'
git config --file "$GIT_CONFIG_GLOBAL" user.email 'convergence@example.invalid'
export CONVERGENCE_ENGINE="$FIXTURE/engine" CONVERGENCE_LOG="$FIXTURE/actions"
export XDG_STATE_HOME="$FIXTURE/state with spaces"
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
    'network ls'|'volume ls')
        for resource in "$state/$kind."*; do
            [[ -f "$resource" ]] || continue
            printf '%s\n' "${resource##*/$kind.}"
        done
        ;;
    'image exists') [[ ${CONVERGENCE_IMAGE_MISSING:-false} != true ]] ;;
    'container exists'|'network exists'|'volume exists') [[ -f "$file" ]] ;;
    'container inspect'|'network inspect'|'volume inspect')
        [[ -f "$file" ]] || exit 125
        template=${5:-}
        if [[ ${CONVERGENCE_INSPECT_ERROR:-} == "$kind" ]]; then exit 125; fi
        if [[ "$template" = *'{{printf "|"}}'* ]]; then
            while [[ "$template" = *'{{printf "|"}}'* ]]; do
                predicate=${template%%'{{printf "|"}}'*}
                template=${template#*'{{printf "|"}}'}
                if [[ -n ${CONVERGENCE_BAD_PROPERTY:-} && "$predicate" = *"$CONVERGENCE_BAD_PROPERTY"* ]]; then
                    printf 'false|'
                else
                    printf 'true|'
                fi
            done
            printf '\n'
            exit 0
        fi
        case "$template" in
            '{{.ID}} {{le .Created.UnixNano '*)
                original=true
                [[ ! -f "$file.recreated" ]] || original=false
                printf '%064d %s\n' 3 "$original" ;;
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
        if [[ ${CONVERGENCE_FAIL_MUTATION:-} == "$kind:before" ]]; then exit 42; fi
        label=""
        while (($#)); do
            case "$1" in --label) label=${2#*=}; shift ;; esac
            name=$1; shift
        done
        echo "$label" > "$state/$kind.$name"
        mkdir -p "$state/home"
        if [[ ${CONVERGENCE_FAIL_MUTATION:-} == "$kind:after" ]]; then exit 42; fi
        ;;
    'network rm'|'volume rm'|'image rm')
        printf '%s\n' "$*" >> "$log"
        rm -f "$file"
        [[ "$kind" != network ]] || rm -f "$file.recreated"
        ;;
    *)
        case "$kind" in
            ps)
                if [[ -n ${CONVERGENCE_FOREIGN_NETWORK:-} && "$*" = *"network=$CONVERGENCE_FOREIGN_NETWORK"* ]]; then
                    printf 'foreign-container\n'
                fi
                ;;
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
if [[ -n ${CONVERGENCE_SSH_LOG:-} ]]; then printf "%s\n" "$command" >> "$CONVERGENCE_SSH_LOG"; fi
if [[ ${CONVERGENCE_SSH_FAILURE:-} == true ]]; then exit 255; fi
if [[ ${CONVERGENCE_UPSTREAM_FAILURE:-} == true && "$command" == *https://example.com/* ]]; then exit 6; fi
if [[ ${CONVERGENCE_DENIAL_TRANSPORT_FAILURE:-} == true && "$command" == *--write-out* ]]; then exit 6; fi
if [[ -n ${CONVERGENCE_CONNECT_FAILURES:-} && "$command" == *--write-out* ]]; then
    printf 'proxy-connect\n' >> "$CONVERGENCE_LOG"
    attempts=$(grep -c '^proxy-connect$' "$CONVERGENCE_LOG")
    if ((attempts <= CONVERGENCE_CONNECT_FAILURES)); then exit 28; fi
fi
case "$command" in
    'bash -s -- '*) cat >/dev/null; printf '%s\n' "${CONVERGENCE_SESSION_RESULT:-ok}" ;;
    *'--write-out'*) printf '%s' "${CONVERGENCE_DENIAL_CODE:-403}" ;;
    *'jailbox-manage-proxy enable'*|*'jailbox-manage-proxy disable'*) echo sync >> "$CONVERGENCE_LOG" ;;
    *'jailbox-manage-proxy check-enable'*|*'jailbox-manage-proxy check-disable'*)
        [[ ${CONVERGENCE_MANAGED_SETTINGS_FAILURE:-} != true ]] ;;
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
    if launch up > "$FIXTURE/stdout" 2> "$FIXTURE/output"; then
        echo 'unexpected convergence success'
        cat "$FIXTURE/stdout" "$FIXTURE/output"
        exit 1
    fi
    if ! grep -q "$1" "$FIXTURE/output" || grep -q 'Sandbox is ready' "$FIXTURE/stdout"; then
        cat "$FIXTURE/stdout" "$FIXTURE/output"
        exit 1
    fi
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
