#!/bin/bash
# Batched checks retain each refusal and reject malformed/failed producers.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR=$ROOT
# shellcheck source=host/container-runtime.sh
source "$ROOT/host/container-runtime.sh"
# shellcheck source=host/validation.sh
source "$ROOT/host/validation.sh"
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
cmp "$ROOT/container/checks/validate-session.sh" "$tmp/payload"
for token in authorized-keys project-write sockets hardening proxy-env direct-route mount:0 mount:1 mount:2 'mount:999999999999999999999999' garbage; do
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
        cmp "$ROOT/container/checks/validate-session.sh" "$tmp/runtime-payload" || return 1
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
chmod 700 "$tmp/project"
printf key > "$tmp/authorized"
chmod 600 "$tmp/authorized"
sed -e "s@/run/jailbox-sshd/authorized_keys@$tmp/authorized@g" \
    -e "s@/usr/local/lib/jailbox/@$ROOT/container/runtime/lib/jailbox/@g" \
    -e "s@/var/run/docker.sock@$tmp/docker.sock@g" \
    -e "s@/run/podman/podman.sock@$tmp/podman.sock@g" \
    -e "s@/proc/self/mountinfo@$tmp/mountinfo@g" \
    -e "s@/proc/1/status@$tmp/process@g" \
    -e "s@/proc/net/ipv6_route@$tmp/ipv6@g" \
    -e "s@/proc/net/route@$tmp/route@g" \
    "$ROOT/container/checks/validate-session.sh" > "$tmp/remote"
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
remote() { bash -s -- full "$tmp/project" '' "${paths[@]}" < "$tmp/remote"; }
healthy
result=$(remote)
[[ "$result" = ok ]] || fail "healthy remote payload rejected: $result"
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
        bash -s -- full "$tmp/project" "$proxy" "${paths[@]}" < "$tmp/remote"
}
[[ $(proxy_remote) = ok ]] || fail 'healthy proxy session rejected'
[[ $(HTTP_PROXY=wrong bash "$tmp/remote" full "$tmp/project" "$proxy" "${paths[@]}") = proxy-env ]] || fail 'wrong proxy environment accepted'
printf 'eth0 00000000\n' >> "$tmp/route"
[[ $(proxy_remote) = direct-route ]] || fail 'direct IPv4 route accepted'
healthy
printf '00000000000000000000000000000000 00 unused eth0\n' > "$tmp/ipv6"
[[ $(proxy_remote) = direct-route ]] || fail 'direct IPv6 route accepted'
healthy
cat > "$tmp/bin/awk" <<'STUB'
#!/bin/bash
exit 42
STUB
chmod 755 "$tmp/bin/awk"
[[ $(PATH="$tmp/bin:$PATH" remote) = mount:0 ]] || fail 'failed mount-table reader accepted'
printf 'PASS: batched inspection and SSH checks retain refusals, framing, paths and producer failures\n'
