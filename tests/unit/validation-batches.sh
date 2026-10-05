#!/bin/bash
# Batched checks retain each refusal and reject malformed/failed producers.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR=$ROOT/src
# shellcheck source=src/host/core/resources/container.sh
source "$ROOT/src/host/core/resources/container.sh"
# shellcheck source=src/host/core/commands/status.sh
source "$ROOT/src/host/core/commands/status.sh"
# shellcheck source=src/host/core/resources/inventory.sh
source "$ROOT/src/host/core/resources/inventory.sh"
# shellcheck source=src/host/core/resources/home.sh
source "$ROOT/src/host/core/resources/home.sh"
# shellcheck source=src/host/core/commands/stop.sh
source "$ROOT/src/host/core/commands/stop.sh"
# shellcheck source=src/host/core/resources/runtime-files.sh
source "$ROOT/src/host/core/resources/runtime-files.sh"
# shellcheck source=src/host/core/commands/clean.sh
source "$ROOT/src/host/core/commands/clean.sh"
# shellcheck source=src/host/core/commands/up.sh
source "$ROOT/src/host/core/commands/up.sh"
# shellcheck source=src/host/core/checks/compatibility.sh
source "$ROOT/src/host/core/checks/compatibility.sh"
# shellcheck source=src/host/core/resources/ssh.sh
source "$ROOT/src/host/core/resources/ssh.sh"
# shellcheck source=src/host/core/checks/attachment.sh
source "$ROOT/src/host/core/checks/attachment.sh"
# shellcheck source=src/host/core/resources/container.sh
source "$ROOT/src/host/core/resources/container.sh"
# shellcheck source=src/host/core/resources/proxy.sh
source "$ROOT/src/host/core/resources/proxy.sh"
# shellcheck source=src/host/core/resources/downloader.sh
source "$ROOT/src/host/core/resources/downloader.sh"
# shellcheck source=src/host/core/commands/connection-info.sh
source "$ROOT/src/host/core/commands/connection-info.sh"
# shellcheck source=src/host/core/checks/compatibility.sh
source "$ROOT/src/host/core/checks/compatibility.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { fail "$@"; }
refuse_sandbox() { fail "$@"; }
reply=$'true|true|true|true|\n'
producer_status=0
podman() { printf 'inspect\n' >> "$tmp/calls"; printf '%s' "$reply"; return "$producer_status"; }
validate_container_hardening fixture
[[ $(wc -l < "$tmp/calls") = 1 ]] || fail 'hardening did not batch inspections'
for field in 0 1 2 3; do
    values=(true true true true)
    values[field]=false
    printf -v reply '%s|%s|%s|%s|\n' "${values[@]}"
    if (validate_container_hardening fixture) > "$tmp/out" 2>&1; then fail "accepted hardening field $field"; fi
done
for reply in '' $'true|true|true|true|' $'true|true|true|\n' $'true|true|true|true|extra|\n' $'true|true|true|true|\n\n'; do
    if (validate_container_hardening fixture) > "$tmp/out" 2>&1; then fail 'accepted malformed inspection'; fi
done
reply=$'true|true|true|true|\n'
producer_status=125
if (validate_container_hardening fixture) > "$tmp/out" 2>&1; then fail 'accepted failed inspection with plausible output'; fi

REMOTE_PATH='/project with spaces'
# This transport fixture supplies finalized state directly, including unusual
# bytes used to test argument encoding independently of config validation.
PROJECT_PATH_POLICY_READY=true
EFFECTIVE_READONLY_PATHS=('policy with spaces' $'literal\\path\nnext')
EGRESS_ALLOW=()
validation_ssh() {
    printf '%s\n' "$*" >> "$tmp/ssh-calls"
    cat > "$tmp/payload"
    printf '%s' "$reply"
    return "$producer_status"
}
producer_status=0
reply=$'ok\n'
validate_running_development
[[ $(wc -l < "$tmp/ssh-calls") = 1 ]] || fail 'session checks did not use one SSH call'
cmp "$ROOT/src/container/checks/validate-session.sh" "$tmp/payload"
for token in identity authorized-keys project-write sockets hardening proxy-env direct-route mount:0 mount:1 mount:2 'mount:999999999999999999999999' garbage; do
    reply="$token"$'\n'
    if (validate_running_development) > "$tmp/out" 2>&1; then fail "accepted remote failure $token"; fi
done
for reply in '' ok $'ok\n\n' $'noise\nok\n'; do
    if (validate_running_development) > "$tmp/out" 2>&1; then fail 'accepted malformed SSH response'; fi
    grep -Fq 'check shell startup files for unexpected output' "$tmp/out" || fail 'missing unexpected-output guidance'
done
reply=$'ok\n'
for producer_status in 1 255; do
    if (validate_running_development) > "$tmp/out" 2>&1; then fail 'accepted failed SSH with plausible output'; fi
    grep -Fq "SSH validation command failed (exit $producer_status; transport or remote execution error)" "$tmp/out" || fail 'misleading SSH failure diagnostic'
done
producer_status=0
cp "$tmp/ssh-calls" "$tmp/ssh-before"
mkdir -p "$tmp/invalid-install/container/checks/validate-session.sh"
for install in "$tmp/missing-install" "$tmp/invalid-install"; do
    # shellcheck disable=SC2030 # Invalid installations are isolated fixtures.
    if (SCRIPT_DIR=$install; validate_running_development) > "$tmp/out" 2>&1; then fail 'accepted unreadable local payload'; fi
    grep -Fq 'could not read local validation payload' "$tmp/out" || fail 'misreported local payload failure'
    cmp "$tmp/ssh-before" "$tmp/ssh-calls" || fail 'SSH ran after local payload read failure'
done
(
    # shellcheck disable=SC2030 # Mount-only configuration is intentionally local.
    EGRESS_ALLOW=(example.com)
    unset NETWORK_STATE
    check_readonly_mounts
)

# The real runtime harness has its own SCRIPT_DIR. It must scope the CLI root
# while calling host validation and restore its directory afterward.
(
    # shellcheck source=tests/integration/runtime-security.sh
    source "$ROOT/tests/integration/runtime-security.sh"
    JAILBOX_DIR=$ROOT
    SCRIPT_DIR="$ROOT/tests/integration"
    mkdir "$tmp/runtime-project"
    printf 'unchanged\n' > "$tmp/runtime-project/Dockerfile"
    pass() { printf '%s\n' "$*" >> "$tmp/runtime-passes"; }
    ssh() {
        cat > "$tmp/runtime-payload" || return 1
        cmp "$ROOT/src/container/checks/validate-session.sh" "$tmp/runtime-payload" || return 1
        case "$*" in
            *Dockerfile*) printf 'mount:3\n' ;;
            *.github/workflows*) printf 'mount:1\n' ;;
            *) printf 'ok\n' ;;
        esac
    }
    assert_readonly_mount_validation fixture-config "$tmp/runtime-project"
    [[ "$SCRIPT_DIR" = "$ROOT/tests/integration" ]] || fail 'runtime harness changed its script directory'
    [[ $(wc -l < "$tmp/runtime-passes") = 4 ]] || fail 'runtime mount checks did not all pass'
)

# Execute the real payload against fixture kernel files. Only absolute input
# locations are redirected; the predicates and awk programs stay unchanged.
# Socket checks must also use fixture paths: CI hosts may run Docker or Podman.
mkdir "$tmp/project" "$tmp/bin"
cp "$ROOT/tests/fixtures/validation-id.sh" "$tmp/bin/id"
chmod 755 "$tmp/bin/id"
chmod 700 "$tmp/project"
printf key > "$tmp/authorized"
chmod 600 "$tmp/authorized"
sed -e "s@/run/jailbox-sshd/authorized_keys@$tmp/authorized@g" \
    -e "s@/usr/local/lib/jailbox/@$ROOT/src/container/runtime/lib/jailbox/@g" \
    -e "s@/var/run/docker.sock@$tmp/docker.sock@g" \
    -e "s@/run/podman/podman.sock@$tmp/podman.sock@g" \
    -e "s@/proc/self/mountinfo@$tmp/mountinfo@g" \
    -e "s@/proc/1/status@$tmp/process@g" \
    -e "s@/proc/net/ipv6_route@$tmp/ipv6@g" \
    -e "s@/proc/net/route@$tmp/route@g" \
    "$ROOT/src/container/checks/validate-session.sh" > "$tmp/remote"
paths=(/ '/project with spaces/policy' $'/literal\\path\nnext')
mounts() {
    local path encoded
    for path in "${paths[@]}"; do
        encoded=${path//\\/\\134}
        encoded=${encoded// /\\040}
        encoded=${encoded//$'\n'/\\012}
        printf '1 0 0:1 / %s ro - tmpfs tmpfs ro\n' "$encoded"
    done > "$tmp/mountinfo"
}
healthy() {
    mounts
    printf 'CapEff:\t0000000000000000\nCapBnd:\t0000000000000000\nNoNewPrivs:\t1\n' > "$tmp/process"
    printf 'Iface Destination\neth0 01000000\n' > "$tmp/route"
    : > "$tmp/ipv6"
}
remote() { PATH="$tmp/bin:$PATH" bash -s -- full "$tmp/project" '' true 0 0 "${paths[@]}" < "$tmp/remote"; }
healthy
result=$(remote)
[[ "$result" = ok ]] || fail "healthy remote payload rejected: $result"
for identity in missing-user missing-group root managed-mismatch wrong-uid wrong-gid; do
    [[ $(VALIDATION_ID_CASE="$identity" remote) = identity ]] || fail "invalid remote identity accepted: $identity"
done
for field in CapEff CapBnd NoNewPrivs; do
    healthy
    sed "/^$field:/d" "$tmp/process" > "$tmp/changed"
    mv "$tmp/changed" "$tmp/process"
    [[ $(remote) = hardening ]] || fail "missing $field accepted"
done
healthy
printf 'CapEff:\t0000000000000001\n' > "$tmp/process"
[[ $(remote) = hardening ]] || fail 'capabilities accepted'
healthy
sed '2s/ ro / rw /' "$tmp/mountinfo" > "$tmp/changed"
mv "$tmp/changed" "$tmp/mountinfo"
[[ $(remote) = mount:1 ]] || fail 'writable protected mount accepted'
healthy
sed '3d' "$tmp/mountinfo" > "$tmp/changed"
mv "$tmp/changed" "$tmp/mountinfo"
[[ $(remote) = mount:2 ]] || fail 'missing protected mount accepted'
healthy
head -1 "$tmp/mountinfo" >> "$tmp/duplicate"
cat "$tmp/duplicate" >> "$tmp/mountinfo"
[[ $(remote) = mount:0 ]] || fail 'duplicate mount accepted'
healthy
rm "$tmp/authorized"
[[ $(remote) = authorized-keys ]] || fail 'missing authentication file accepted'
printf key > "$tmp/authorized"
chmod 600 "$tmp/authorized"
proxy=http://10.0.0.2:8888
proxy_remote() {
    HTTP_PROXY="$proxy" HTTPS_PROXY="$proxy" http_proxy="$proxy" https_proxy="$proxy" \
        NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 \
        PATH="$tmp/bin:$PATH" bash -s -- full "$tmp/project" "$proxy" true 0 0 "${paths[@]}" < "$tmp/remote"
}
[[ $(proxy_remote) = ok ]] || fail 'healthy proxy session rejected'
[[ $(PATH="$tmp/bin:$PATH" HTTP_PROXY=wrong bash "$tmp/remote" full "$tmp/project" "$proxy" true 0 0 "${paths[@]}") = proxy-env ]] || fail 'wrong proxy environment accepted'
printf 'eth0 00000000\n' >> "$tmp/route"
[[ $(proxy_remote) = direct-route ]] || fail 'direct IPv4 route accepted'
healthy
printf '00000000000000000000000000000000 00 unused eth0\n' > "$tmp/ipv6"
[[ $(proxy_remote) = direct-route ]] || fail 'direct IPv6 route accepted'
healthy
# The same payload observes lanes without mutation for attachment, and only
# launch probes directories. File-only policies must never create a sibling.
mkdir "$tmp/project/lane"
printf original > "$tmp/project/file"
chmod 755 "$tmp/project/lane"
chmod 644 "$tmp/project/file"
healthy
printf '2 0 0:1 / %s ro - tmpfs tmpfs ro\n' "$tmp/project" >> "$tmp/mountinfo"
printf '3 0 0:1 / %s rw - tmpfs tmpfs rw\n' "$tmp/project/lane" "$tmp/project/file" >> "$tmp/mountinfo"
lane_remote() {
    PATH="$tmp/bin:$PATH" bash "$tmp/remote" "$1" "$tmp/project" '' false 2 0 \
        "$tmp/project/lane" "$tmp/project/file" / "$tmp/project"
}
touch -t 200001010000 "$tmp/lane-timestamp" "$tmp/project/lane"
[[ $(lane_remote full) = ok ]] || fail 'read-only base produced false project-write refusal'
[[ ! "$tmp/project/lane" -nt "$tmp/lane-timestamp" ]] || fail 'read-only validation changed lane timestamp'
[[ $(lane_remote launch) = ok ]] || fail 'directory launch probe failed'
[[ "$tmp/project/lane" -nt "$tmp/lane-timestamp" ]] || fail 'launch did not exercise directory write probe'
[[ -z $(find "$tmp/project/lane" -mindepth 1 -print) ]] || fail 'launch marker leaked'
[[ $(cat "$tmp/project/file") = original ]] || fail 'validator modified a user file'
(
    # A failing allocation must never run during attachment or file-only launch.
    # shellcheck disable=SC2329
    mktemp() { return 42; }
    export -f mktemp
    [[ $(lane_remote full) = ok ]] || fail 'attachment attempted marker allocation'
    [[ $(lane_remote launch) = lane-write ]] || fail 'failed marker allocation accepted'
    [[ $(PATH="$tmp/bin:$PATH" bash "$tmp/remote" launch "$tmp/project" '' false 1 0 \
        "$tmp/project/file" / "$tmp/project") = ok ]] || fail 'file-only launch attempted a marker'
)
(
    # Failure with plausible output must still clean up only its own marker.
    # shellcheck disable=SC2329
    mktemp() { command mktemp "$@"; return 42; }
    export -f mktemp
    [[ $(lane_remote launch) = lane-write ]] || fail 'failed marker producer accepted'
)
[[ -z $(find "$tmp/project/lane" -mindepth 1 -print) ]] || fail 'failed allocation leaked marker'
for failure in status signal; do
    (
        export PROBE_FAIL_ONCE="$tmp/probe-failed-$failure" PROBE_FAILURE="$failure"
        # shellcheck disable=SC2329
        rm() {
            if [[ ! -e "$PROBE_FAIL_ONCE" ]]; then
                : > "$PROBE_FAIL_ONCE"
                if [[ "$PROBE_FAILURE" = signal ]]; then kill -TERM "$BASHPID"; fi
                return 42
            fi
            command rm "$@"
        }
        export -f rm
        if [[ "$failure" = status ]]; then
            [[ $(lane_remote launch) = probe-cleanup ]] || fail 'failed marker removal accepted'
        elif lane_remote launch; then
            fail 'interrupted probe succeeded'
        fi
    )
    [[ -z $(find "$tmp/project/lane" -mindepth 1 -print) ]] || fail 'failed or interrupted removal leaked marker'
done
printf existing > "$tmp/project/lane/.jailbox-write.preexisting"
[[ $(lane_remote launch) = ok ]] || fail 'launch with existing marker failed'
[[ $(cat "$tmp/project/lane/.jailbox-write.preexisting") = existing ]] || fail 'probe removed a pre-existing file'
sed 's/ rw / ro /' "$tmp/mountinfo" > "$tmp/changed"
mv "$tmp/changed" "$tmp/mountinfo"
[[ $(lane_remote full) = lane-mount ]] || fail 'read-only lane accepted'
# Exercise native mask observation with synthetic mount records and real
# empty-directory/null-device shapes. No write probe is permitted here.
mkdir "$tmp/masked-directory"
chmod 755 "$tmp/masked-directory"
mask_remote() {
    PATH="$tmp/bin:$PATH" bash "$tmp/remote" mounts "$tmp/project" '' false 0 4 \
        file "$mask_file" directory "$tmp/masked-directory" / "$tmp/project"
}
mask_mounts() {
    healthy
    {
        printf '2 0 0:1 / %s ro - tmpfs tmpfs ro\n' "$tmp/project"
        printf '3 0 0:2 /null %s rw - tmpfs tmpfs rw\n' "$mask_file"
        printf '4 0 0:3 / %s ro - tmpfs tmpfs ro\n' "$tmp/masked-directory"
    } >> "$tmp/mountinfo"
}
mask_file=/dev/null
mask_mounts
[[ $(mask_remote) = ok ]] || fail 'valid native mask representations rejected'
for mask_file in "$tmp/project/file" /dev/zero; do
    mask_mounts
    [[ $(mask_remote) = hidden-mask ]] || fail 'mask with wrong inode/device accepted'
done
mask_file=/dev/null
for defect in missing duplicate writable wrong-type shared child contents; do
    mask_mounts
    case "$defect" in
        missing) sed '$d' "$tmp/mountinfo" > "$tmp/changed"; mv "$tmp/changed" "$tmp/mountinfo" ;;
        duplicate) tail -1 "$tmp/mountinfo" >> "$tmp/changed"; cat "$tmp/changed" >> "$tmp/mountinfo" ;;
        writable|wrong-type|shared)
            case "$defect" in writable) rule='s/ ro / rw /' ;; wrong-type) rule='s/- tmpfs/- ext4/' ;; shared) rule='s/ - / shared:4 - /' ;; esac
            sed "\$ $rule" "$tmp/mountinfo" > "$tmp/changed"; mv "$tmp/changed" "$tmp/mountinfo" ;;
        child) printf '5 4 0:4 / %s/child rw - tmpfs tmpfs rw\n' "$tmp/masked-directory" >> "$tmp/mountinfo" ;;
        contents) printf exposed > "$tmp/masked-directory/exposed" ;;
    esac
    [[ $(mask_remote) = hidden-mask ]] || fail "ineffective mask accepted: $defect"
done
rm "$tmp/masked-directory/exposed"
mask_mounts
for producer in stat find; do
    partial=''
    [[ "$producer" != stat ]] || partial=1:3
    printf '#!/bin/bash\nprintf "%%s" %q\nexit 42\n' "$partial" > "$tmp/bin/$producer"
    chmod 755 "$tmp/bin/$producer"
    [[ $(mask_remote) = hidden-mask ]] || fail "failed mask $producer producer accepted"
    rm "$tmp/bin/$producer"
done
healthy
cat > "$tmp/bin/awk" <<'STUB'
#!/bin/bash
exit 42
STUB
chmod 755 "$tmp/bin/awk"
[[ $(PATH="$tmp/bin:$PATH" remote) = mount:0 ]] || fail 'failed mount-table reader accepted'
printf 'PASS: batched inspection and SSH checks retain refusals, framing, paths and producer failures\n'
