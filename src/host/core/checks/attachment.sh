# checks — attachment

validate_existing_sandbox_health() {
    if [ "$UP_DEV_STATE" = running ]; then
        validate_running_development
    fi
    if [ "$UP_PROXY_STATE" = running ]; then
        validate_proxy_ready
    fi
    if [ "$UP_DEV_STATE" = running ] && [ "$UP_PROXY_STATE" = running ]; then
        check_proxy_egress_denied
    fi
}

post_start_validation() {
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        check_downloader_proxy_config
        check_proxy_egress_denied
        check_proxy_egress_allowed
    else
        check_downloader_proxy_config_absent
    fi
    echo '✅ Sandbox is ready'
}

# One read-only attachment boundary, shared by all transport consumers.
validate_attachment() {
    require_command podman || return 1
    require_command ssh || return 1
    require_command ssh-keygen || return 1
    require_command realpath || return 1
    initialize_project_names || return 1
    initialize_config_digest_state || return 1
    initialize_dev_image_state || return 1
    initialize_ssh_state || return 1
    initialize_network_state || return 1
    initialize_container_runtime_state || return 1
    initialize_convergence_state || return 1
    initialize_runtime_ids || return 1
    validate_ssh_state_path || return 1
    validate_configured_readonly_paths || return 1
    require_compatible_home || return 1
    compute_config_digest attach || return 1
    require_compatible_project_resources attach || return 1
    inspect_sandbox_for_up attach || return 1
    [ "$UP_DEV_STATE" = running ] || die "development sandbox is $UP_DEV_STATE; run 'jailbox up' before attaching"
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        [ "$UP_PROXY_STATE" = running ] || die "proxy is $UP_PROXY_STATE; run 'jailbox up' before attaching"
    fi
    validate_running_development || return 1
    validate_proxy_ready || return 1
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        check_proxy_egress_denied || return 1
        check_downloader_proxy_config || return 1
    else
        check_downloader_proxy_config_absent || return 1
    fi
}
