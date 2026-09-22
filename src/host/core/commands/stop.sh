# commands — stop

stop_jailbox() {
    local target policy=false
    local -a present=() removable=()

    resolve_present_resources present \
        "container:$CONTAINER_NAME" \
        "container:$PROXY_NAME" \
        "network:$NETWORK_NAME" \
        "network:${NETWORK_NAME}-internal" \
        "network:${NETWORK_NAME}-external" \
        "volume:$VOLUME_NAME"

    if [[ " ${present[*]} " == *" volume:$VOLUME_NAME "* ]]; then
        policy=$(home_retention_policy) || return $?
        [ "$policy" != corrupt ] || \
            printf "Warning: home '%s' has corrupt retention metadata; preserving it.\n" "$VOLUME_NAME" >&2
    fi

    for target in "${present[@]}"; do
        if [[ "$target" = "volume:$VOLUME_NAME" && "$policy" != true ]]; then
            continue
        fi
        removable+=("$target")
    done
    if [ -z "${removable[*]-}" ]; then
        # Orphaned credentials are removable state even when no Podman object is,
        # so report the cleanup instead of claiming there was nothing to do.
        assert_ssh_state_initialized
        if ssh_generation_present; then
            remove_ssh_generation || return 1
            echo "🧹 Removed orphaned SSH credentials."
        else
            echo "No jailbox resources to stop."
        fi
        return 0
    fi
    echo "🛑 Stopping jailbox..."
    for target in "${removable[@]}"; do
        remove_project_resource "$target"
    done
    remove_ssh_generation || return 1
    echo "✅ Stopped"
}

run_stop() {
    initialize_project_names
    require_command podman
    initialize_ssh_state
    stop_jailbox
}
