# commands — status

# Inventory is independent of policy, retention labels, SSH state, and health.
# Discard even existence output: a failed engine must not leak plausible
# success bytes onto the machine stream. Probe every resource before publishing.
run_status() {
    local target probe running result=absent
    local -a inventory=()

    require_command podman
    initialize_project_names
    inventory=(
        "container:$CONTAINER_NAME" "container:$PROXY_NAME"
        "network:$NETWORK_NAME" "network:${NETWORK_NAME}-internal"
        "network:${NETWORK_NAME}-external" "volume:$VOLUME_NAME"
    )
    for target in "${inventory[@]}"; do
        probe=0
        jailbox_resource_exists "${target%%:*}" "${target#*:}" >/dev/null || probe=$?
        case "$probe" in
            1) continue ;;
            0) ;;
            *) die "could not inspect project resource inventory" ;;
        esac
        [[ "$result" != absent ]] || result=stopped
        if [[ "$target" = "container:$CONTAINER_NAME" ]]; then
            running=$(inspect_container_running "$CONTAINER_NAME") || return 1
            [[ "$running" != running ]] || result=running
        fi
    done
    printf '%s\n' "$result"
}
