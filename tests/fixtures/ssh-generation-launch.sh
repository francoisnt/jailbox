#!/bin/bash
set -euo pipefail
# shellcheck disable=SC1091
source "$GENERATION_REPO/src/host/core/common.sh"
# shellcheck disable=SC1091
source "$GENERATION_REPO/src/host/core/ssh.sh"
# shellcheck disable=SC1091
source "$GENERATION_REPO/src/host/core/container-runtime.sh"
# shellcheck disable=SC1091
source "$GENERATION_FIXTURE/launch-function"
die() { echo "$*" >&2; exit 1; }
PROJECT_STATE_ROOT="$GENERATION_FIXTURE/launch-state"
PROJECT_HASH="$GENERATION_FAILURE"
CONTAINER_NAME=jailbox-test
LOCAL_PORT=50222
MANAGED_USER=jailbox
NETWORK_SSH_SESSION_ENV=()
initialize_ssh_state
initialize_runtime_ids() { :; }
PROXY_NAME=jailbox-test-proxy
VOLUME_NAME=jailbox-test-home
inspect_sandbox_for_up() { UP_DEV_STATE=absent; }
build_current_proxy_image() { :; }
validate_existing_sandbox_health() { :; }
validate_configured_readonly_paths() { :; }
check_local_port_available() { :; }
require_compatible_home() { :; }
compute_config_digest() { :; }
require_compatible_project_resources() { :; }
build_or_select_dev_image() { :; }
validate_dev_image() { :; }
finalize_effective_readonly_paths() { :; }
build_jailbox_image() { :; }
configure_network() { :; }
build_readonly_mounts() { [ "$GENERATION_FAILURE" != before ]; }
ensure_home_volume() { :; }
start_jailbox_container() {
    # The new pin must already exist when the engine is first invoked.
    validate_ssh_generation
    printf '%064d' 1 > "$SSH_GENERATION_DIR/container-id"
    chmod 640 "$SSH_GENERATION_DIR/container-id"
    touch "$GENERATION_FIXTURE/container-$GENERATION_FAILURE"
    [ "$GENERATION_FAILURE" != during ]
}
wait_for_ssh() { return 1; }
podman() {
    case "$1 $2" in
        'container exists') [ "$3" = "$CONTAINER_NAME" ] && [ -f "$GENERATION_FIXTURE/container-$GENERATION_FAILURE" ] ;;
        'volume exists') return 1 ;;
        'rm -f')
            [ -f "$KEY_FILE" ] || exit 1
            rm "$GENERATION_FIXTURE/container-$GENERATION_FAILURE"
            ;;
        *) return 125 ;;
    esac
}
bring_up_sandbox
