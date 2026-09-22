# commands — clean

clean_jailbox() {
    local target name
    local -a present=() images=()

    while IFS= read -r name; do
        images+=("image:$name")
    done < <(project_cleanup_images)

    # Every target is probed before anything is removed; containers first so
    # the networks and the volume are free.
    resolve_present_resources present \
        "container:$CONTAINER_NAME" \
        "container:$PROXY_NAME" \
        "network:$NETWORK_NAME" \
        "network:${NETWORK_NAME}-internal" \
        "network:${NETWORK_NAME}-external" \
        "volume:$VOLUME_NAME" \
        "${images[@]}"

    printf "Warning: --clean permanently deletes this project's home and runtime state, and removes its three derived image names.\n" >&2
    echo "🧹 Cleaning up..."
    for target in "${present[@]}"; do
        remove_project_resource "$target"
    done
    rm -rf -- "$SSH_DIR"
    echo "✅ Done"
}

run_clean() {
    initialize_project_names
    require_command podman
    initialize_launch_state
    clean_jailbox
}
