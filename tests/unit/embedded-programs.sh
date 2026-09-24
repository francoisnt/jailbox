#!/bin/bash
# Extracted programs must retain their data and failure contracts.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mount_state() { awk -v target=/auth -v prefix=/auth/ -f "$ROOT/src/container/runtime/lib/jailbox/authentication-mount.awk" "$tmp/mounts"; }
printf '1 2 0:3 / /auth ro - tmpfs tmpfs ro\n' > "$tmp/mounts"
[[ $(mount_state) = ok ]] || fail 'read-only authentication mount rejected'
printf '4 1 0:5 / /auth/key rw - tmpfs tmpfs rw\n' >> "$tmp/mounts"
[[ $(mount_state) = 'nested: /auth/key' ]] || fail 'writable authentication overlay accepted'
printf '1 2 0:3 / /auth rw - tmpfs tmpfs rw\n' > "$tmp/mounts"
[[ $(mount_state) = writable:rw ]] || fail 'writable authentication mount accepted'
: > "$tmp/mounts"
[[ $(mount_state) = absent ]] || fail 'absent authentication mount accepted'
export EXPECTED_GATEWAY=10.89.0.1
printf 'Iface Destination Gateway\neth0 00000000 0100590A\n' > "$tmp/routes"
awk -f "$ROOT/src/container/checks/proxy-route.awk" "$tmp/routes" || fail 'valid gateway rejected'
for route in 'eth0 00000000 0200590A' 'eth0 0000590A 00000000' ''; do
    printf 'Iface Destination Gateway\n%s\n' "$route" > "$tmp/routes"
    if awk -f "$ROOT/src/container/checks/proxy-route.awk" "$tmp/routes"; then fail 'invalid default route accepted'; fi
done
printf 'Iface Destination Gateway\neth0 00000000 0100590A\neth1 00000000 0100590A\n' > "$tmp/routes"
if awk -f "$ROOT/src/container/checks/proxy-route.awk" "$tmp/routes"; then fail 'duplicate default routes accepted'; fi
mkdir -m 700 "$tmp/home"
printf '{"task.allowAutomaticTasks":"on"}\n' > "$tmp/settings"
HOME="$tmp/home" bash "$ROOT/src/container/runtime/bin/jailbox-write-editor-settings" < "$tmp/settings"
cmp "$tmp/settings" "$tmp/home/.vscodium-server/data/Machine/settings.json"
cmp "$tmp/settings" "$tmp/home/.vscode-server/data/Machine/settings.json"
# Execute a real wrapper stage that returns on build failure. Its EXIT cleanup
# runs after function locals disappear and must retain the container identity.
result=0
(
    # Runner is checked separately; this fixture replaces its dependencies.
    # shellcheck source=/dev/null
    source "$ROOT/tests/integration/wrapper-images.sh"
    # shellcheck disable=SC2034 # Inputs to the runner stage.
    PASSED=0 FAILED=0 JAILBOX_DIR=$ROOT BASE_IMAGE_DEBIAN=debian BASE_IMAGE_ALPINE=alpine BASE_IMAGE_FEDORA=fedora
    # shellcheck disable=SC2329 # Called by the runner stage.
    stage_port() { printf '2222\n'; }
    # shellcheck disable=SC2329
    stage_forward_port() { printf '2223\n'; }
    # shellcheck disable=SC2329
    podman() { printf '%s\n' "$*" >> "$tmp/engine"; }
    # shellcheck disable=SC2329
    test_log_capture() { : > "$1"; return 1; }
    # shellcheck disable=SC2329 # Called by the runner stage.
    fail() { FAILED=$((FAILED + 1)); }
    run_case debian "$tmp"
) > "$tmp/stage-output" 2>&1 || result=$?
[[ "$result" = 1 ]] || fail 'wrapper cleanup changed build failure status'
[[ $(cat "$tmp/debian.counts") = '0 1' ]] || fail 'wrapper cleanup lost stage counts'
[[ $(grep -Fxc 'rm jailbox-test-debian-ctr' "$tmp/engine") = 2 ]] || fail 'wrapper cleanup lost container identity after return'

HOME="$tmp/home" bash "$ROOT/tests/lib/sandbox/check-managed-proxy.sh" absent
HOME="$tmp/home" bash "$ROOT/src/container/runtime/bin/jailbox-manage-proxy" enable http://127.0.0.1:8888
for client in curl wget; do
    HOME="$tmp/home" bash "$ROOT/tests/lib/sandbox/check-managed-proxy.sh" "$client" http://127.0.0.1:8888
    if HOME="$tmp/home" bash "$ROOT/tests/lib/sandbox/check-managed-proxy.sh" "$client" http://wrong:8888; then
        fail 'managed proxy check accepted the wrong URL'
    fi
done
if HOME="$tmp/home" bash "$ROOT/tests/lib/sandbox/check-managed-proxy.sh" absent; then
    fail 'managed proxy check missed stale settings'
fi
if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/tests/lib/editor/build-proof-vsix.py" "$ROOT/tests/e2e/fixtures/proof-extension" "$tmp/proof extension.vsix"
    python3 -m zipfile -t "$tmp/proof extension.vsix"
else
    printf 'SKIP: proof extension packaging requires python3 (editor prerequisite)\n'
fi
printf 'PASS: extracted mount, gateway, and editor-setting programs preserve their contracts\n'
