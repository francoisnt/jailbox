# commands — stop

stop_jailbox() {
    local target policy=absent
    local -a present=() removable=()

    resolve_project_resources present

    if [[ " ${present[*]} " == *" volume:$VOLUME_NAME "* ]]; then
        policy=$(home_retention_policy) || return $?
        [ "$policy" != corrupt ] || \
            printf "Warning: home '%s' has corrupt retention metadata; preserving it.\n" "$VOLUME_NAME" >&2
    fi

    retire_forwarding || return 1

    for target in "${present[@]}"; do
        if [[ "$target" = "volume:$VOLUME_NAME" && "$policy" != true ]]; then
            continue
        fi
        removable+=("$target")
    done
    if [ -n "${removable[*]-}" ]; then
        echo "🛑 Stopping jailbox..."
        remove_project_resources "${removable[@]}" || return 1
    fi
    # A prior stop can have removed the volume before reaching its receipt.
    if [[ "$policy" = true || "$policy" = absent ]]; then
        remove_home_setup_record || return 1
    fi
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
    remove_ssh_generation || return 1
    echo "✅ Stopped"
}

run_stop() {
    initialize_project_names
    require_command podman
    initialize_ssh_state
    stop_jailbox
}
