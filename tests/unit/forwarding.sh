#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 -I -B "$ROOT/tests/lib/forwarding-test.py"

# Exercise the public CLI with a deterministic engine and a socket-backed SSH
# double. The runtime gate covers OpenSSH and the actual container bind mounts.
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
export CONVERGENCE_FORWARD_ROOT="$ROOT"
state="${GENERATION%/*}/forwarding"
cleanup_forwarding_fixture() {
    if [[ -d "$state" ]]; then
        chmod 700 "$state"
        launch stop >/dev/null || true
    fi
    rm -rf -- "$FIXTURE"
}
trap cleanup_forwarding_fixture EXIT
export JAILBOX_CONFIG_HOST_COMMAND_POLICY=host-policy
expect_failure 'HOST_COMMAND_POLICY path does not exist'
printf 'hostname {{[z-a]}}\n' > "$FIXTURE/project/host-policy"
chmod 644 "$FIXTURE/project/host-policy"
expect_failure 'HOST_COMMAND_POLICY line 1'
[[ ! -e "$CONVERGENCE_LOG" ]]
printf 'hostname\n' > "$FIXTURE/project/host-policy"
JAILBOX_CONFIG_HIDDEN_PATHS_0=host-policy expect_failure 'conflicts with HIDDEN_PATHS'
cp "$ROOT/tests/fixtures/forwarding/host-command.py" "$FIXTURE/project/project-tool"
chmod 755 "$FIXTURE/project/project-tool"
printf 'project-tool\n' > "$FIXTURE/project/host-policy"
PATH="$FIXTURE/project:$PATH" expect_failure 'inside the project tree'
printf 'jailbox-unavailable-test-command\n' > "$FIXTURE/project/host-policy"
expect_failure 'is unavailable'
printf 'hostname\n' > "$FIXTURE/project/host-policy"

mkdir -m 755 "$FIXTURE/project/hidden"
printf 'fixture contents\n' > "$FIXTURE/project/hidden-file"
chmod 644 "$FIXTURE/project/hidden-file"
export JAILBOX_CONFIG_HIDDEN_PATHS_0=hidden JAILBOX_CONFIG_HIDDEN_PATHS_1=hidden-file
expect_success
[[ -x "$GENERATION/server/host-commands/hostname" ]]
[[ -f "$state/policy" ]]
python3 -c '
import json, os, sys
info = os.stat(sys.argv[2])
with open(sys.argv[1]) as manifest:
    assert json.load(manifest)["hidden_directories"] == [[info.st_dev, info.st_ino]]
' "$state/manifest" "$FIXTURE/project/hidden"
grep -Fq "$FIXTURE/project/host-policy:/home/jailbox/project/host-policy:Z,ro,rprivate" "$CONVERGENCE_LOG"
before=$(snapshot)
expect_success
[[ "$before" = "$(snapshot)" ]]
printf '# changed by the host\n' >> "$FIXTURE/project/host-policy"
expect_failure 'jailbox stop'
cmp -s "$state/policy" <(printf 'hostname\n')
launch stop

for recovery in stop --clean; do
    expect_success
    podman rm -f "$PREFIX"
    mv "$FIXTURE/project/host-policy" "$FIXTURE/policy-saved"
    launch status
    chmod 000 "$state"
    if launch "$recovery" > "$FIXTURE/output" 2>&1; then
        chmod 700 "$state"
        echo 'recovery accepted an unobservable forwarding directory' >&2
        exit 1
    fi
    chmod 700 "$state"
    grep -Fq 'forwarding state' "$FIXTURE/output"
    podman network exists "$PREFIX-net"
    [[ -d "$GENERATION" && -d "$state" ]]
    launch "$recovery"
    [[ ! -e "$state" ]]
    mv "$FIXTURE/policy-saved" "$FIXTURE/project/host-policy"
done

unset JAILBOX_CONFIG_HOST_COMMAND_POLICY
expect_success
[[ ! -e "$state" && ! -e "$GENERATION/server/host-commands" ]]
launch stop
