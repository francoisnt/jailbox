#!/bin/bash
# Generation identity, damaged-state refusal, and invocation-only cleanup.
# shellcheck disable=SC2317 # Stubs are called indirectly by sourced validators.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JAILBOX_DIR=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=src/host/core/common.sh
source "$JAILBOX_DIR/src/host/core/common.sh"
# shellcheck source=src/host/core/ssh.sh
source "$JAILBOX_DIR/src/host/core/ssh.sh"
# shellcheck source=src/host/core/container-runtime.sh
source "$JAILBOX_DIR/src/host/core/container-runtime.sh"
FIXTURE=$(mktemp -d)
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
die() { echo "Error: $*" >&2; exit 1; }
PROJECT_STATE_ROOT="$FIXTURE/state"
PROJECT_HASH="test"
CONTAINER_NAME=jailbox-test
LOCAL_PORT=50222
MANAGED_USER=jailbox
PROXY_NAME=jailbox-test-proxy
VOLUME_NAME=jailbox-test-home
NETWORK_SSH_SESSION_ENV=()
declare -A NETWORK_STATE=([proxy_url]="")
initialize_ssh_state

reject() {
    if "$@" > "$FIXTURE/error" 2>&1; then
        echo "FAIL: expected refusal: $*" >&2; exit 1
    fi
    grep -q 'SSH generation' "$FIXTURE/error"
}

reject_state_path() {
    if "$@" > "$FIXTURE/error" 2>&1; then
        echo "FAIL: expected refusal: $*" >&2; exit 1
    fi
    # Recovery must name the offending path instead of repeating stop/up advice
    # that neither command can carry out through a substituted state path.
    grep -q "SSH state path '$SSH_DIR'" "$FIXTURE/error" &&
        ! grep -q 'jailbox stop' "$FIXTURE/error"
}

# Retained material must announce itself: the message is the only thing telling
# a caller which state survived a failed rollback and how to recover it.
reject_rollback() {
    local expected="$1"
    shift
    if "$@" > "$FIXTURE/error" 2>&1; then
        echo "FAIL: expected refusal: $*" >&2; exit 1
    fi
    grep -q "$expected" "$FIXTURE/error"
}

snapshot() {
    find "$SSH_GENERATION_DIR" -type f -exec cksum {} + | sort
}

create_ssh_generation
validate_ssh_generation
before=$(snapshot)
validate_ssh_generation
[ "$before" = "$(snapshot)" ]
reject create_ssh_generation
[ "$before" = "$(snapshot)" ]
cp -R "$SSH_GENERATION_DIR" "$FIXTURE/pristine"

for damage in missing symlink directory fifo owner mode server_pair client_pair authorized pin config parent_mode parent_link; do
    rm -rf "$SSH_GENERATION_DIR"
    cp -R "$FIXTURE/pristine" "$SSH_GENERATION_DIR"
    case "$damage" in
        missing) rm "$KEY_FILE" ;;
        symlink) rm "$KEY_FILE"; ln -s "$FIXTURE/pristine/key" "$KEY_FILE" ;;
        directory) rm "$KEY_FILE"; mkdir "$KEY_FILE" ;;
        fifo) rm "$KEY_FILE"; mkfifo "$KEY_FILE" ;;
        owner)
            # Exercise the ownership result without requiring host chown rights.
            ssh_file_metadata() { printf '999999:600\n'; }
            ;;
        mode) chmod 644 "$KEY_FILE" ;;
        server_pair) cp "$KEY_FILE.pub" "$SSHD_RUNTIME_DIR/ssh_host_ed25519_key.pub" ;;
        client_pair) cp "$SSHD_RUNTIME_DIR/ssh_host_ed25519_key.pub" "$KEY_FILE.pub" ;;
        authorized) printf 'altered\n' >> "$SSHD_RUNTIME_DIR/authorized_keys" ;;
        pin) printf '\n' >> "$KNOWN_HOSTS" ;;
        config) printf '    StrictHostKeyChecking no\n' >> "$SSH_CONFIG" ;;
        parent_mode) chmod 777 "$SSHD_RUNTIME_DIR" ;;
        parent_link) rm -rf "$SSHD_RUNTIME_DIR"; ln -s "$FIXTURE/pristine/server" "$SSHD_RUNTIME_DIR" ;;
    esac
    damaged=$(snapshot)
    reject validate_ssh_generation
    [ "$damaged" = "$(snapshot)" ]
    if [ "$damage" = owner ]; then
        ssh_file_metadata() { stat -c '%u:%a' "$1" 2>/dev/null || stat -f '%u:%Lp' "$1"; }
    fi
    echo "PASS: rejects $damage"
done
remove_ssh_generation
printf 'keep\n' > "$SSH_DIR/gitconfig"
create_ssh_generation
[ "$before" != "$(snapshot)" ]
[ "$(cat "$SSH_DIR/gitconfig")" = keep ]
remove_ssh_generation
mkdir "$SSH_DIR/.ssh-generation.interrupted"
reject require_ssh_generation_absent
remove_ssh_generation
remove_ssh_generation
[ -f "$SSH_DIR/gitconfig" ]

# Refusing a symlinked state root must not follow it during explicit cleanup.
mv "$SSH_DIR" "$SSH_DIR.saved"
ln -s "$SSH_DIR.saved" "$SSH_DIR"
reject_state_path remove_ssh_generation
[ -f "$SSH_DIR.saved/gitconfig" ]
rm "$SSH_DIR"
mv "$SSH_DIR.saved" "$SSH_DIR"

# A failing second key generation must remove the first pair and staging dir.
real_keygen=$(command -v ssh-keygen)
mkdir "$FIXTURE/bin"
cat > "$FIXTURE/bin/ssh-keygen" <<'STUB'
#!/bin/bash
case "$*" in *server/ssh_host*) exit 1 ;; esac
exec "$REAL_KEYGEN" "$@"
STUB
chmod +x "$FIXTURE/bin/ssh-keygen"
if (export REAL_KEYGEN="$real_keygen"; PATH="$FIXTURE/bin:$PATH"; create_ssh_generation); then
    echo 'FAIL: generation failure was ignored' >&2; exit 1
fi
if ssh_generation_present; then echo 'FAIL: preparation leaked state'; exit 1; fi

create_ssh_generation
container_id=$(printf '%064d' 1)
printf '%s\n' "$container_id" > "$SSH_GENERATION_DIR/container-id"
# Podman writes this receipt under the caller's umask; fix a representative
# mode here so the suite exercises the engine's range rather than one default.
chmod 640 "$SSH_GENERATION_DIR/container-id"
UP_CREATED=("container:$CONTAINER_NAME")
UP_HOST_CREATED=("$SSH_GENERATION_DIR")
container_present=true
podman() {
    case "$1 $2" in
        'container exists') [ "$3" = "$CONTAINER_NAME" ] && [ "$container_present" = true ] ;;
        'rm -f') [ "$3" = "$CONTAINER_NAME" ] && [ -f "$KEY_FILE" ]; container_present=false ;;
        *) return 1 ;;
    esac
}
rollback_ssh_launch 1
if ssh_generation_present; then echo 'FAIL: rollback leaked state'; exit 1; fi
create_ssh_generation
printf '%s\n' "$container_id" > "$SSH_GENERATION_DIR/container-id"
chmod 600 "$SSH_GENERATION_DIR/container-id"
# shellcheck disable=SC2329 # Called indirectly through reject_rollback.
podman() { return 125; }
reject_rollback 'cleanup could not remove' rollback_ssh_launch 1
[ -f "$KEY_FILE" ]

# Before container creation, confirmed absence permits cleanup. An engine
# inspection error must retain the generation for explicit stop recovery.
rm "$SSH_GENERATION_DIR/container-id"
reject_rollback 'cleanup could not remove' rollback_ssh_launch 1
[ -f "$KEY_FILE" ]
podman() { return 1; }
rollback_ssh_launch 1
if ssh_generation_present; then echo 'FAIL: pre-container rollback leaked state'; exit 1; fi
create_ssh_generation
printf '%s\n' "$container_id" > "$SSH_GENERATION_DIR/container-id"
chmod 640 "$SSH_GENERATION_DIR/container-id"

# Inspection failure and mismatched mounts fail closed; no SSH process runs.
# shellcheck disable=SC2329 # Called indirectly through reject.
podman() {
    if [ "$5" = '{{.Id}}' ]; then printf '%s\n' "$container_id"; else printf 'invalid\n'; fi
}
reject validate_ssh_resume
# shellcheck disable=SC2329 # Called indirectly through reject.
podman() { return 125; }
reject validate_ssh_resume
podman() {
    if [ "$5" = '{{.Id}}' ]; then printf '%s\n' "$container_id"; else printf 'ok\n'; fi
}
validate_ssh_resume
# The immutable container input must match policy even when keys and mounts
# remain healthy. Reject missing, different, duplicated, or failed inspections.
podman() {
    case "$5" in
        '{{.Id}}') printf '%s\n' "$container_id" ;;
        *'.Config.Env'*) printf '%s\n' "$session_inspection"; return "$session_inspection_status" ;;
        *) printf 'ok\n' ;;
    esac
}
session_inspection_status=0
for session_inspection in '' invalid okok okinvalid; do
    before_refusal=$(snapshot)
    reject validate_ssh_resume
    [[ $(snapshot) == "$before_refusal" ]]
done
session_inspection=ok
session_inspection_status=125
reject validate_ssh_resume
session_inspection_status=0
validate_ssh_resume
# Any private receipt mode resumes; shared write access refuses, because that
# is what would let another account forge the recorded identity.
chmod 600 "$SSH_GENERATION_DIR/container-id"
validate_ssh_resume
chmod 664 "$SSH_GENERATION_DIR/container-id"
reject validate_ssh_resume
chmod 640 "$SSH_GENERATION_DIR/container-id"
podman() { printf '%064d\n' 2; }
reject validate_ssh_resume


# Exercise the production launch ordering and EXIT trap with actual key creation.
# Only image/network work is stubbed; each failure runs in a fresh Bash process
# so errexit has its normal CLI semantics.
sed -n '/^bring_up_sandbox() {$/,/^}$/p' "$JAILBOX_DIR/src/host/core/entry.sh" > "$FIXTURE/launch-function"
grep -q '^bring_up_sandbox() {' "$FIXTURE/launch-function"
cp "$JAILBOX_DIR/tests/fixtures/ssh-generation-launch.sh" "$FIXTURE/launch-test"
for phase in before during readiness; do
    if GENERATION_REPO="$JAILBOX_DIR" GENERATION_FIXTURE="$FIXTURE" GENERATION_FAILURE="$phase" \
        bash "$FIXTURE/launch-test"; then
        echo "FAIL: launch ignored $phase failure"; exit 1
    fi
    [ ! -e "$FIXTURE/container-$phase" ]
    [ ! -e "$FIXTURE/launch-state/projects/$phase/ssh-generation" ]
    echo "PASS: launch trap rolls back $phase failure"
done

echo 'SSH generation tests passed'
