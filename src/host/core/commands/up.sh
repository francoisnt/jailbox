# NETWORK_STATE is the associative map declared by resources/network.sh.
# shellcheck disable=SC2154
# commands — up

# One operation owns attempted creations, convergence, and rollback.
UP_CREATED=()
UP_HOST_CREATED=()
UP_CONVERGING=false

initialize_convergence_state() {
    UP_CONVERGING=false
}

reset_up_attempts() {
    UP_CREATED=()
    UP_HOST_CREATED=()
}

track_up_host_path() {
    UP_HOST_CREATED+=("$1")
}

# Armed after compatibility inspection, before the first sandbox mutation.
rollback_ssh_launch() {
    [ "$1" -eq 0 ] || rollback_up_launch
}

begin_up_convergence() {
    UP_CONVERGING=true
}

fail_sandbox_readiness() {
    die "sandbox convergence failed after startup or synchronization began: $*. Sandbox state may have changed; cleanup and retained-resource reporting follow."
}

up_resource_present() {
    local target
    for target in "${UP_PRESENT[@]}"; do
        [ "$target" != "$1" ] || return 0
    done
    return 1
}

track_up_resource() {
    up_resource_present "$1" || UP_CREATED+=("$1")
    return 0
}

rollback_up_launch() {
    local target kind name probe failed=false dependent=false state path index
    local dev_retained=false proxy_retained=false needed
    # Never stop a survivor. If removal fails, preserve all potentially needed
    # dependencies and authentication, even when the survivor is stopped.
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        for target in "${UP_CREATED[@]}"; do
            [ "$target" = "container:$name" ] || continue
            if [ "$name" = "$PROXY_NAME" ]; then
                probe=0
                jailbox_resource_exists container "$CONTAINER_NAME" || probe=$?
                if [ "$probe" -ne 1 ]; then
                    printf "Retained dependency '%s' for surviving development container.\n" "$name" >&2
                    continue
                fi
            fi
            probe=0
            jailbox_resource_exists container "$name" || probe=$?
            [ "$probe" -ne 1 ] || continue
            if [ "$probe" -ne 0 ] || ! podman rm -f "$name"; then
                failed=true
                printf "Error: cleanup could not remove '%s'; dependencies retained.\n" "$name" >&2
            fi
        done
    done
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        probe=0
        jailbox_resource_exists container "$name" || probe=$?
        [ "$probe" -eq 1 ] || dependent=true
        if [ "$probe" -ne 1 ]; then
            if [ "$name" = "$CONTAINER_NAME" ]; then dev_retained=true; else proxy_retained=true; fi
        fi
        if [ "$probe" -eq 0 ]; then
            state=$(podman container inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || state=unknown
            printf "Retained container '%s': %s.\n" "$name" "$state" >&2
        fi
    done
    for ((index=${#UP_CREATED[@]}-1; index>=0; index--)); do
        target=${UP_CREATED[index]}
        kind=${target%%:*}; name=${target#*:}
        [ "$kind" != container ] || continue
        needed=$dependent
        [ "$kind" != volume ] || needed=$dev_retained
        if [ "$needed" = true ]; then
            printf "Retained dependency '%s'.\n" "$target" >&2
            continue
        fi
        probe=0
        jailbox_resource_exists "$kind" "$name" || probe=$?
        [ "$probe" -ne 1 ] || continue
        if [ "$probe" -ne 0 ] || ! podman "$kind" rm "$name"; then
            failed=true
            printf "Error: cleanup retained '%s'.\n" "$target" >&2
        fi
    done
    for ((index=${#UP_HOST_CREATED[@]}-1; index>=0; index--)); do
        path=${UP_HOST_CREATED[index]}
        needed=$dev_retained
        case "$path" in
            "$SSH_DIR") needed=$dependent ;;
            "$SSH_DIR/tinyproxy-filter"|"$SSH_DIR/tinyproxy.conf") needed=$proxy_retained ;;
        esac
        if [ "$needed" = true ]; then
            printf "Retained launch material '%s' needed by a surviving container.\n" "$path" >&2
        elif [ "$path" = "$SSH_DIR" ]; then
            rmdir "$path" 2>/dev/null || true
        elif ! rm -rf -- "$path"; then
            failed=true
            printf "Error: cleanup retained host material '%s'.\n" "$path" >&2
        fi
    done
    up_stop_guidance >&2 || true
    [ "$failed" = false ]
}

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

configure_network() {
    # Every network carries the digest, so no network is created before the
    # current configuration has one.
    assert_config_digest_ready || return 1

    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        configure_proxy_network || return 1
    else
        if ! up_resource_present "network:$NETWORK_NAME"; then
            track_up_resource "network:$NETWORK_NAME"
            podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$NETWORK_NAME" || return 1
        fi
        NETWORK_STATE[selected_network]="$NETWORK_NAME"
        NETWORK_SSH_SESSION_ENV=()
        NETWORK_STATE[proxy_url]=""
        NETWORK_STATE[no_proxy]=""
    fi
}

configure_proxy_network() {
    # Egress enforcement model: direct container egress is blocked by an
    # internal-only Podman network (no external route). Outbound HTTP(S) is
    # brokered exclusively through the tinyproxy sidecar, which enforces the
    # EGRESS_ALLOW domain allowlist. Enforcement is proxy-mediated
    # (protocol/domain filter), not per-packet or firewall-level.
    #
    # Rootless, zero-capability Podman intentionally avoids NET_ADMIN,
    # iptables/nftables, and TUN/TProxy interception. Hostname-aware
    # transparent filtering would require one of those mechanisms. The chosen
    # topology trades transparent filtering for a simpler, capability-free
    # model: tools must cooperate with proxy configuration (HTTP_PROXY /
    # HTTPS_PROXY env, curlrc, wgetrc) to reach allowed hosts.
    local internal_net external_net effective_egress_allow proxy_internal_ip proxy_internal_subnet

    effective_egress_allowlist effective_egress_allow || return 1
    NETWORK_STATE[filter_file]="$SSH_DIR/tinyproxy-filter"

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    ensure_internal_network "$internal_net" || return 1
    if ! up_resource_present "network:$external_net"; then
        track_up_resource "network:$external_net"
        podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$external_net" || return 1
    fi

    # Derive the proxy address from the network's actual subnet rather than
    # recomputing the hash candidate: an existing network may have been
    # created on a fallback subnet after a collision.
    proxy_internal_subnet=$(internal_network_subnet "$internal_net") || {
        echo "Error: could not determine subnet of internal network $internal_net" >&2
        return 1
    }
    [ -n "$proxy_internal_subnet" ] || die "could not determine subnet of internal network $internal_net"
    proxy_internal_ip=$(proxy_ip_for_subnet "$proxy_internal_subnet") || return 1

    NETWORK_STATE[proxy_conf_file]="$SSH_DIR/tinyproxy.conf"
    if [ "$UP_PROXY_STATE" = absent ]; then
        prepare_proxy_files || return 1
        render_tinyproxy_filter "${NETWORK_STATE[filter_file]}" "${effective_egress_allow[@]}" || return 1
        render_tinyproxy_conf "${NETWORK_STATE[proxy_conf_file]}" "$proxy_internal_subnet" || return 1
        track_up_resource "container:$PROXY_NAME"

        start_proxy_container "$internal_net" "$external_net" "$proxy_internal_ip" "${#effective_egress_allow[@]}" || return 1
    elif [ "$UP_PROXY_STATE" != running ]; then
        podman start "$PROXY_NAME" || return 1
    fi

    NETWORK_STATE[selected_network]="$internal_net"
    NETWORK_STATE[internal_network]="$internal_net"
    NETWORK_STATE[proxy_url]="http://$proxy_internal_ip:8888"
    configure_proxy_env
}
