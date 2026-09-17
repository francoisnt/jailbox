#!/bin/bash
# Exercise host callers with real payloads across simulated transport boundaries.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=host/ssh.sh
source "$ROOT/host/ssh.sh"
# shellcheck source=host/validation.sh
source "$ROOT/host/validation.sh"
# shellcheck source=host/editor.sh
source "$ROOT/host/editor.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf '%s\n' "$*" >&2; exit 1; }
refuse_sandbox() { die "$@"; }
SCRIPT_DIR=$ROOT
UP_CONVERGING=false
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

# The settings helper receives JSON on stdin; script transport must not replace it.
SSH_CONFIG="$tmp/ssh config"
CONTAINER_NAME=fixture
JAILBOX_EDITOR_SMOKE_TEST_SETTINGS=1
ssh_transport_status=0
mkdir -m 700 "$tmp/home"
ssh() {
    [[ "$1" = -F && "$2" = "$SSH_CONFIG" && "$3" = "$CONTAINER_NAME" &&
       "$4" = /usr/local/bin/jailbox-write-editor-settings ]] || return 98
    HOME="$tmp/home" bash "$ROOT/container/runtime/bin/jailbox-write-editor-settings" || return $?
    return "$ssh_transport_status"
}
editor_smoke_settings_json_object > "$tmp/expected"
write_remote_editor_smoke_settings
cmp "$tmp/expected" "$tmp/home/.vscode-server/data/Machine/settings.json"
cmp "$tmp/expected" "$tmp/home/.vscodium-server/data/Machine/settings.json"
ssh_transport_status=42
result=0
write_remote_editor_smoke_settings || result=$?
[[ "$result" = 42 ]] || fail 'editor settings lost transport failure status'
printf 'PASS: streamed validation and editor settings preserve stdin, refusal sequencing, and transport status\n'
