#!/bin/bash
# Exercise host callers with real payloads across simulated transport boundaries.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/core/resources/ssh.sh
source "$ROOT/src/host/core/resources/ssh.sh"
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
die() { printf '%s\n' "$*" >&2; exit 1; }
refuse_sandbox() { die "$@"; }
SCRIPT_DIR=$ROOT/src
LAUNCH_CONVERGING=false
EGRESS_ALLOW=(example.com)
NETWORK_NAME=fixture-net
PROXY_NAME=fixture-proxy
declare -A NETWORK_STATE=([proxy_url]=http://10.0.0.2:8888)
transport_status=0
podman() {
    printf '%s\n' "$*" >> "$tmp/calls"
    case "$1 $2" in
        'container inspect') printf '10.89.0.1\n' ;;
        'exec -i')
            [[ "$3" = -e && "$5" = "$PROXY_NAME" && "$6" = awk &&
               "$7" = -f && "$8" = - && "$9" = /proc/net/route ]] || return 98
            # Preserve streamed program and environment; substitute only the
            # kernel route-table input, which belongs to the simulated container.
            env "$4" awk -f - "$tmp/routes" || return $?
            return "$transport_status"
            ;;
        "exec $PROXY_NAME") printf 'HTTP/1.0 403 Forbidden\r\n\r\n' ;;
        *) return 99 ;;
    esac
}
printf 'Iface Destination Gateway\neth0 00000000 0100590A\n' > "$tmp/routes"
validate_proxy_ready
[[ $(wc -l < "$tmp/calls") = 3 ]] || fail 'healthy proxy did not complete both checks'

for scenario in bad-route transport missing directory; do
    : > "$tmp/calls"
    if (
        case "$scenario" in
            bad-route) printf 'Iface Destination Gateway\neth0 00000000 0200590A\n' > "$tmp/routes" ;;
            transport)
                printf 'Iface Destination Gateway\neth0 00000000 0100590A\n' > "$tmp/routes"
                transport_status=125
                ;;
            missing|directory)
                SCRIPT_DIR="$tmp/$scenario"
                mkdir -p "$SCRIPT_DIR/container/checks"
                if [[ "$scenario" = directory ]]; then mkdir "$SCRIPT_DIR/container/checks/proxy-route.awk"; fi
                ;;
        esac
        validate_proxy_ready
    ) > "$tmp/output" 2>&1; then fail "accepted $scenario proxy check"; fi
    if grep -Fq "exec $PROXY_NAME " "$tmp/calls"; then fail 'denial probe ran after failed route preparation or validation'; fi
    case "$scenario" in
        missing|directory)
            [[ $(wc -l < "$tmp/calls") = 1 ]] || fail 'remote execution followed missing local payload'
            grep -Fq 'repair the jailbox installation' "$tmp/output" || fail 'missing local repair guidance'
            ;;
        *) grep -Fq 'proxy external default route is not ready' "$tmp/output" || fail 'missing route refusal' ;;
    esac
done

printf 'PASS: streamed validation preserves refusal sequencing and transport status\n'
