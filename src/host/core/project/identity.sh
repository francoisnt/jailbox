# project — identity

PROJECT_HASH=""
PROJECT_RESOURCE_PREFIX=""
PROJECT_STATE_ROOT=""
CONTAINER_NAME=""
PROXY_NAME=""
PROXY_IMAGE=""
VOLUME_NAME=""
NETWORK_NAME=""
LOCAL_PORT=""
MY_UID=""
MANAGED_USER="jailbox"
REMOTE_PATH="/home/jailbox/project"

project_path_hash() {
    jailbox_project_hash_for_path "$PROJECT_DIR"
}

initialize_project_names() {
    # Identity is derived before any preflight, so a host with neither
    # SHA-256 tool fails here — with the dependency diagnostic the hash helper
    # prints — instead of continuing with an empty or partial name.
    PROJECT_HASH=$(project_path_hash) || die "could not derive project identity"
    # Podman resources carry the project name for readability; the hash of
    # the full path remains the identity. State directories below stay keyed
    # on the hash alone.
    PROJECT_RESOURCE_PREFIX=$(jailbox_resource_prefix_for_path "$PROJECT_DIR") || die "could not derive project resource identity"
    PROJECT_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox"
    CONTAINER_NAME="${PROJECT_RESOURCE_PREFIX}"
    PROXY_NAME="${PROJECT_RESOURCE_PREFIX}-proxy"
    PROXY_IMAGE="${PROJECT_RESOURCE_PREFIX}-proxy"
    VOLUME_NAME="${PROJECT_RESOURCE_PREFIX}-home"
    NETWORK_NAME="${PROJECT_RESOURCE_PREFIX}-net"
}

initialize_runtime_ids() {
    local offset

    # Stable port derived from the full project path (49152-65534).
    offset=$(jailbox_project_hash_port_offset "$PROJECT_HASH") || exit 1
    LOCAL_PORT=$(( 49152 + offset ))
    MY_UID=$(id -u)
}
