# Read-only mounts, persistent home, cleanup, container start, and editor launch.

configure_readonly_paths() {
    READONLY_PATHS=(
        "Containerfile"
        "Dockerfile"
        ".devcontainer/Containerfile"
        ".devcontainer/Dockerfile"
        ".git/config"
        ".git/config.lock"
        ".git/hooks"
        ".gitignore"
        ".gitmodules"
        ".env"
        ".gitea/workflows"
        ".github/workflows"
        ".jailbox"
        ".ssh/config"
        ".ssh/jailbox_key"
        ".ssh/jailbox_key.pub"
        ".ssh/known_hosts"
        "jailbox"
        "jailbox.conf"
    )

    # If jailbox lives inside the project, protect the whole submodule/directory.
    if [[ "$SCRIPT_DIR" == "$PROJECT_DIR/"* ]]; then
        local submodule_rel
        submodule_rel="${SCRIPT_DIR#$PROJECT_DIR/}"
        READONLY_PATHS=("$submodule_rel" "${READONLY_PATHS[@]}")
    fi
}

build_readonly_mounts() {
    local path
    READONLY_MOUNTS=()
    for path in "${READONLY_PATHS[@]}"; do
        [ -e "$PROJECT_DIR/$path" ] && READONLY_MOUNTS+=(-v "$PROJECT_DIR/$path:$REMOTE_PATH/$path:Z,ro")
    done
}

configure_runtime_mounts() {
    GITCONFIG_MOUNT=()
    [ -f ~/.gitconfig ] && GITCONFIG_MOUNT=(-v "$HOME/.gitconfig:/home/$DEV_USER/.gitconfig:ro")

    # The container root filesystem is always read-only. Project and home
    # writes go through explicit mounts; runtime state uses tmpfs mounts.
    ROOTFS_FLAG=(--read-only)
}

clean_jailbox() {
    echo "🧹 Cleaning up..."
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
    podman stop "$PROXY_NAME" 2>/dev/null || true
    podman rm "$PROXY_NAME" 2>/dev/null || true
    podman volume rm "$VOLUME_NAME" 2>/dev/null || true
    podman network rm "$NETWORK_NAME" 2>/dev/null || true
    podman network rm "${NETWORK_NAME}-internal" 2>/dev/null || true
    podman network rm "${NETWORK_NAME}-external" 2>/dev/null || true
    echo "✅ Done"
}

ensure_home_volume() {
    if ! podman volume exists "$VOLUME_NAME" 2>/dev/null; then
        podman volume create "$VOLUME_NAME"
        VOLUME_PATH=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}')
        podman unshare chown "$(id -u):$(id -g)" "$VOLUME_PATH"
    fi
}

start_jailbox_container() {
    echo "🚢 Starting jailbox..."
    podman run -d \
        --name "$CONTAINER_NAME" \
        --replace \
        --userns=keep-id \
        --network "$JAILBOX_NETWORK" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m,noexec \
        --tmpfs /run:rw,size=64m \
        -v "$VOLUME_NAME":/home/$DEV_USER \
        "${GITCONFIG_MOUNT[@]}" \
        -p 127.0.0.1:"$LOCAL_PORT":2222 \
        -v "$PROJECT_DIR:$REMOTE_PATH:Z" \
        -v "$KEY_FILE.pub:/home/$DEV_USER/.ssh/authorized_keys:ro,Z" \
        "${READONLY_MOUNTS[@]}" \
        "${PROXY_ENV[@]}" \
        --memory=4g \
        --cpus=2 \
        --pids-limit=256 \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --cap-add=CHOWN,DAC_OVERRIDE,FOWNER,SETUID,SETGID,SYS_CHROOT \
        "$JAILBOX_IMAGE"
}

open_editor() {
    echo "🚀 Connecting..."
    "$EDITOR_BIN" --remote "ssh-remote+$CONTAINER_NAME" "$REMOTE_PATH"
}
