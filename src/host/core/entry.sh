# Core command initialization and lifecycle dispatch.
# shellcheck source=src/host/core/common.sh
source "$SCRIPT_DIR/host/core/common.sh"
apply_config_defaults
# shellcheck source=src/host/core/preflight.sh
source "$SCRIPT_DIR/host/core/preflight.sh"
# shellcheck source=src/host/core/dev-image.sh
source "$SCRIPT_DIR/host/core/dev-image.sh"
# shellcheck source=src/host/core/ssh.sh
source "$SCRIPT_DIR/host/core/ssh.sh"
# shellcheck source=src/host/core/network.sh
source "$SCRIPT_DIR/host/core/network.sh"
# shellcheck source=src/host/core/downloader-proxy.sh
source "$SCRIPT_DIR/host/core/downloader-proxy.sh"
# shellcheck source=src/host/core/container-runtime.sh
source "$SCRIPT_DIR/host/core/container-runtime.sh"
# shellcheck source=src/host/core/validation.sh
source "$SCRIPT_DIR/host/core/validation.sh"
# shellcheck source=src/host/core/config-digest.sh
source "$SCRIPT_DIR/host/core/config-digest.sh"
# shellcheck source=src/host/core/exec.sh
source "$SCRIPT_DIR/host/core/exec.sh"

bring_up_sandbox() {
    initialize_runtime_ids
    validate_configured_readonly_paths
    # Stored home policy outranks digest incompatibility: stop cannot repair
    # a persistent-to-ephemeral change or corrupt retention metadata.
    require_compatible_home
    # The digest is the compatibility gate for every policy-bearing resource
    # that outlives a single launch, so it is computed — and every surviving
    # resource checked against it — before anything is built or created.
    compute_config_digest launch
    require_compatible_project_resources
    inspect_sandbox_for_up
    if [ "$UP_DEV_STATE" = absent ]; then
        build_or_select_dev_image
        validate_dev_image
        # Classify launch inputs before the wrapper build. Mount construction
        # repeats this to catch subsequent path replacement.
        finalize_effective_readonly_paths
        build_jailbox_image
    fi
    if [ "$UP_PROXY_STATE" = absent ]; then
        build_current_proxy_image
    fi
    validate_existing_sandbox_health
    check_local_port_available "$UP_DEV_STATE"
    # All refusals above are read-only with respect to sandbox resources.
    # Record attempts before mutation so failures inside an engine operation
    # also enter dependency-safe rollback.
    trap 'rollback_ssh_launch "$?"' EXIT
    trap 'exit 1' HUP INT TERM
    begin_up_convergence
    configure_network
    if [ "$UP_DEV_STATE" = absent ]; then
        configure_runtime_mounts
        create_ssh_generation
        build_readonly_mounts
        track_up_resource "volume:$VOLUME_NAME"
        ensure_home_volume
        track_up_resource "container:$CONTAINER_NAME"
        start_jailbox_container
    elif [ "$UP_DEV_STATE" != running ]; then
        resume_jailbox_container
    fi
    wait_for_ssh
    validate_sandbox_structure
    validate_running_development
    validate_proxy_ready
    configure_downloader_proxy
    post_start_validation
    trap - EXIT HUP INT TERM
}

prepare_launch() {
    initialize_project_names
    require_command podman
    load_environment_config
    host_preflight
    initialize_launch_state
}

run_up() {
    prepare_launch
    bring_up_sandbox
}

run_ssh_config() {
    initialize_project_names
    initialize_ssh_state
    print_ssh_config_instructions
}

run_clean() {
    initialize_project_names
    require_command podman
    initialize_launch_state
    clean_jailbox
}

run_stop() {
    initialize_project_names
    require_command podman
    initialize_ssh_state
    stop_jailbox
}

initialize_launch_state() {
    initialize_config_digest_state
    initialize_dev_image_state
    initialize_ssh_state
    initialize_network_state
    initialize_container_runtime_state
}

run_version() {
    local version
    version=$(jailbox_version) || return 1
    printf 'jailbox %s\n' "$version"
}

