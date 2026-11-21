# commands — clean

clean_jailbox() {
    local name
    local -a present=() images=()

    while IFS= read -r name; do
        images+=("image:$name")
    done < <(project_cleanup_images)

    # Every target is probed before anything is removed.
    resolve_project_resources present "${images[@]}"
    retire_forwarding || return 1

    printf "Warning: --clean permanently deletes this project's home and runtime state, and removes its three derived image names.\n" >&2
    echo "🧹 Cleaning up..."
    remove_project_resources "${present[@]}" || return 1
    rm -rf -- "$SSH_DIR"
    echo "✅ Done"
}

run_clean() {
    initialize_project_names
    require_command podman
    initialize_launch_state
    clean_jailbox
}
