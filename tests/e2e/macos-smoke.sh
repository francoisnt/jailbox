#!/usr/bin/env bash
# Focused host/VM integration evidence, not an additional acceptance gate.
set -euo pipefail
JAILBOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
test_log_entrypoint "$JAILBOX_DIR/tests/e2e/macos-smoke.sh" "$@"
# shellcheck source=tests/lib/run-meta.sh
source "$JAILBOX_DIR/tests/lib/run-meta.sh"
# shellcheck source=src/host/frontend/connection.sh
source "$JAILBOX_DIR/src/host/frontend/connection.sh"
# shellcheck source=versions.env
source "$JAILBOX_DIR/versions.env"

fixture=""
project=""
log_dir=""

cli() (cd "$project" && "$JAILBOX_DIR/src/jailbox" "$@")
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$project" ]]; then
        if test_log_capture "$log_dir/cleanup.log" cli --clean; then
            rm -rf -- "$fixture" || { ((status != 0)) || status=1; }
        else
            cat "$log_dir/cleanup.log" >&2
            printf 'Cleanup failed; fixture retained at %s\n' "$fixture" >&2
            ((status != 0)) || status=1
        fi
    elif [[ -n "$fixture" ]]; then
        rm -rf -- "$fixture" || { ((status != 0)) || status=1; }
    fi
    printf 'Smoke result: %s; logs: %s\n' "$status" "$(run_log_path "$log_dir")"
    exit "$status"
}

assert_status() {
    printf '%s\n' "$1" > "$log_dir/status.expected"
    cli status > "$log_dir/status.actual"
    cmp "$log_dir/status.expected" "$log_dir/status.actual" || fail "expected status $1"
}

[[ $# = 0 ]] || fail 'Usage: bash tests/e2e/macos-smoke.sh'
[[ $(uname -s) = Darwin ]] || fail 'this smoke test requires macOS'
case "$(uname -m)" in
    x86_64) architecture=amd64 ;;
    arm64) architecture=arm64 ;;
    *) fail 'unsupported Mac architecture' ;;
esac
for tool in podman ssh ssh-keygen git realpath; do
    command -v "$tool" >/dev/null || fail "missing $tool"
done
[[ $(podman info --format '{{.Host.Security.Rootless}}') = true ]] || fail 'select a rootless Podman Machine connection'
mkdir -p "$JAILBOX_DIR/testlog"
log_dir=$(mktemp -d "$JAILBOX_DIR/testlog/macos-smoke.XXXXXXXX")
write_run_meta "$log_dir"
sw_vers
uname -m
podman version
podman info > "$log_dir/podman-info"
podman machine inspect "${PODMAN_MACHINE_NAME:-jailbox-ci}" > "$log_dir/machine-info" 2>&1 || true

# HOME is shared into Podman Machine. macOS TMPDIR need not be shared.
# Keep both project and private state beneath that share, as separate siblings.
fixture=$(mktemp -d "$HOME/jailbox-macos-smoke.XXXXXXXX")
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fixture=$(cd "$fixture" && pwd -P)
mkdir -p "$fixture/project" "$fixture/state"
chmod 700 "$fixture" "$fixture/state"
chmod 755 "$fixture/project"
export XDG_STATE_HOME="$fixture/state"
export GIT_CONFIG_GLOBAL="$fixture/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0
git config --file "$GIT_CONFIG_GLOBAL" user.name 'Jailbox smoke test'
git config --file "$GIT_CONFIG_GLOBAL" user.email 'smoke@example.invalid'

# Caller policy must not select another image, add mounts, or alter retention.
for variable in "${!JAILBOX_CONFIG_@}"; do unset "$variable"; done
export JAILBOX_CONFIG_DEV_IMAGE="$BASE_IMAGE_DEBIAN"
export JAILBOX_CONFIG_READONLY_PATHS_0=protected-policy
project="$fixture/project"
printf 'protected\n' > "$project/protected-policy"
chmod 644 "$project/protected-policy"

podman pull --arch "$architecture" "$BASE_IMAGE_DEBIAN"
[[ $(podman image inspect "$BASE_IMAGE_DEBIAN" --format '{{.Architecture}}') = "$architecture" ]] || fail 'base image is not native architecture'
podman image inspect "$BASE_IMAGE_DEBIAN" > "$log_dir/base-image"
assert_status absent
cli up
assert_status running
cli connection-info > "$log_dir/connection-info"
parse_connection_records "$log_dir/connection-info"
container=${EDITOR_CONNECTION[ssh_host]}

# Public exec authenticates over the host's forwarded SSH endpoint. The remote
# script must finish successfully after proving that only the protected write
# fails, so a transport failure cannot pass as read-only enforcement.
cli exec sh -s < "$JAILBOX_DIR/tests/lib/sandbox/check-shared-project.sh"
[[ $(cat "$project/from-container") = shared-write ]] || fail 'container write did not reach the Mac'
[[ $(stat -c %u "$project/from-container") = "$(id -u)" ]] || fail 'shared write has incorrect host ownership'
[[ $(cat "$project/protected-policy") = protected ]] || fail 'protected host content changed'
printf 'host-write\n' > "$project/from-host"
host_content=$(cli exec cat /home/jailbox/project/from-host)
[[ "$host_content" = host-write ]] || fail 'host write did not reach the container'
printf 'PASS: native launch, SSH, bidirectional project sharing and read-only protection\n'

cli stop
assert_status stopped
podman volume exists "$container-home"
cli up
# shellcheck disable=SC2016 # Evaluated inside the sandbox.
cli exec sh -c 'test "$(cat "$HOME/smoke-home")" = retained'
printf 'PASS: stop/relaunch preserves a writable home\n'
cli --clean
assert_status absent
for resource in "$container-dev" "$container-image" "$container-proxy"; do
    status=0
    podman image exists "$resource" || status=$?
    [[ "$status" = 1 ]] || fail "derived image removal unverified: $resource"
done
podman image exists "$BASE_IMAGE_DEBIAN"
printf 'PASS: cleanup removes project resources and preserves the external base image\n'
