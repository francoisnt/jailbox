#!/bin/bash
# Read-only SSH validation payload. Emit fixed result tokens, never path bytes.
set -euo pipefail
mode=$1
project=$2
proxy=$3
shift 3
reject() { printf '%s\n' "$1"; exit 0; }
if [[ "$mode" = full ]]; then
    managed_uid=$(id -u jailbox) || reject identity
    managed_gid=$(id -g jailbox) || reject identity
    [[ "$managed_uid" != 0 && "$managed_uid" = "$managed_gid" &&
       $(id -u) = "$managed_uid" && $(id -g) = "$managed_gid" ]] || reject identity
    [[ -f /run/jailbox-sshd/authorized_keys ]] || reject authorized-keys
    [[ -w "$project" ]] || reject project-write
    [[ ! -S /var/run/docker.sock && ! -S /run/podman/podman.sock ]] || reject sockets
elif [[ "$mode" != mounts ]]; then
    exit 1
fi
index=0
for TARGET in "$@"; do
    export TARGET
    # Environment transport preserves backslashes that awk -v would interpret.
    awk -f "/usr/local/lib/jailbox/readonly-mount.awk" /proc/self/mountinfo || reject "mount:$index"
    index=$((index + 1))
done
if [[ "$mode" = full ]]; then
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
printf 'ok\n'
