#!/bin/bash
# Shared SSH validation payload; only launch mode creates temporary markers.
# Emit fixed result tokens, never path bytes.
set -euo pipefail
mode=$1
project=$2
proxy=$3
writable_count=$4
shift 4
writable=("${@:1:writable_count}")
shift "$writable_count"
reject() { printf '%s\n' "$1"; exit 0; }
if [[ "$mode" = full || "$mode" = launch ]]; then
    managed_uid=$(id -u jailbox) || reject identity
    managed_gid=$(id -g jailbox) || reject identity
    [[ "$managed_uid" != 0 && "$managed_uid" = "$managed_gid" &&
       $(id -u) = "$managed_uid" && $(id -g) = "$managed_gid" ]] || reject identity
    [[ -f /run/jailbox-sshd/authorized_keys ]] || reject authorized-keys
    if [[ -z "${writable[*]-}" ]]; then
        [[ -w "$project" ]] || reject project-write
    fi
    [[ ! -S /var/run/docker.sock && ! -S /run/podman/podman.sock ]] || reject sockets
elif [[ "$mode" != mounts ]]; then
    exit 1
fi
# Read-only observations are shared with attachment. Never touch user files.
for TARGET in "${writable[@]}"; do
    export TARGET
    EXPECTED=rw awk -f "/usr/local/lib/jailbox/readonly-mount.awk" /proc/self/mountinfo || reject lane-mount
    [[ -w "$TARGET" ]] || reject lane-write
done
index=0
for TARGET in "$@"; do
    export TARGET
    # Environment transport preserves backslashes that awk -v would interpret.
    EXPECTED=ro awk -f "/usr/local/lib/jailbox/readonly-mount.awk" /proc/self/mountinfo || reject "mount:$index"
    index=$((index + 1))
done
if [[ "$mode" = full || "$mode" = launch ]]; then
    awk -f "/usr/local/lib/jailbox/process-hardening.awk" /proc/1/status || reject hardening
    if [[ -n "$proxy" ]]; then
        for name in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
            [[ ${!name-} = "$proxy" ]] || reject proxy-env
        done
        [[ ${NO_PROXY-} = localhost,127.0.0.1 && ${no_proxy-} = localhost,127.0.0.1 ]] || reject proxy-env
        awk 'NR > 1 && $2 == "00000000" { bad = 1 } END { exit bad }' /proc/net/route || reject direct-route
        if [[ -e /proc/net/ipv6_route ]]; then
            awk '$1 == "00000000000000000000000000000000" && $2 == "00" && $10 != "lo" { bad = 1 } END { exit bad }' /proc/net/ipv6_route || reject direct-route
        fi
    fi
fi
if [[ "$mode" = launch ]]; then
    # mktemp atomically creates a fresh marker; the trap owns only that marker.
    marker=''
    cleanup_marker() {
        [[ -z "$marker" ]] || rm -f -- "$marker"
    }
    trap cleanup_marker EXIT
    trap 'exit 1' HUP INT TERM
    for target in "${writable[@]}"; do
        [[ -d "$target" ]] || continue
        marker=$(mktemp "$target/.jailbox-write.XXXXXXXXXXXX") || reject lane-write
        rm -- "$marker" || reject probe-cleanup
        marker=''
    done
fi
printf 'ok\n'
