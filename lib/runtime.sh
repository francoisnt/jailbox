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
    [ -f ~/.gitconfig ] && GITCONFIG_MOUNT=(-v "$HOME/.gitconfig:/home/$MANAGED_USER/.gitconfig:ro")

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
    rm -rf -- "$SSH_DIR"
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
    # Keep the runtime non-privileged, but restore the narrow privilege set
    # OpenSSH needs after --cap-drop=ALL: DAC_OVERRIDE for strict key and user
    # file checks across mounted homes, SETUID/SETGID for switching
    # authenticated sessions from root sshd to the managed user, and SYS_CHROOT for
    # sshd's privilege-separation path.
    podman run -d \
        --name "$CONTAINER_NAME" \
        --replace \
        --userns=keep-id \
        --network "$JAILBOX_NETWORK" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m,noexec \
        --tmpfs /run:rw,size=64m \
        -v "$VOLUME_NAME":/home/$MANAGED_USER \
        "${GITCONFIG_MOUNT[@]}" \
        -p 127.0.0.1:"$LOCAL_PORT":2222 \
        -v "$PROJECT_DIR:$REMOTE_PATH:Z" \
        -v "$KEY_FILE.pub:/home/$MANAGED_USER/.ssh/authorized_keys:ro,Z" \
        "${READONLY_MOUNTS[@]}" \
        --memory=4g \
        --cpus=2 \
        --pids-limit=256 \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --cap-add=DAC_OVERRIDE,SETUID,SETGID,SYS_CHROOT \
        "$JAILBOX_IMAGE"
}

open_editor() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" true 2>/dev/null; then
        echo "Error: jailbox could not verify SSH before opening the editor." >&2
        echo "SSH config: $SSH_CONFIG" >&2
        echo "Host alias: $CONTAINER_NAME" >&2
        return 1
    fi

    write_jailbox_workspace
    echo "🚀 Connecting..."
    launch_editor_remote
}

launch_editor_remote() {
    write_jailbox_editor_user_settings
    "$EDITOR_BIN" --user-data-dir "$JAILBOX_EDITOR_USER_DATA" \
        --remote "ssh-remote+$CONTAINER_NAME" "$REMOTE_PATH"
}

ensure_jailbox_gitignore() {
    ensure_gitignore_entry ".jailbox/"
}

ensure_gitignore_entry() {
    local entry gitignore_file

    entry="$1"
    gitignore_file="$PROJECT_DIR/.gitignore"

    if [ -f "$gitignore_file" ] && grep -Fxq "$entry" "$gitignore_file"; then
        return 0
    fi

    {
        [ -s "$gitignore_file" ] && printf '\n'
        printf '%s\n' "$entry"
    } >> "$gitignore_file"
}

gitignore_has_entry() {
    local entry gitignore_file

    entry="$1"
    gitignore_file="$PROJECT_DIR/.gitignore"
    [ -f "$gitignore_file" ] && grep -Fxq "$entry" "$gitignore_file"
}

editor_config_has_ssh_config() {
    local config_file

    config_file="$1"
    [ -f "$config_file" ] || return 1
    grep -Fq "\"remote.SSH.configFile\": \"$SSH_CONFIG\"" "$config_file"
}

write_jailbox_workspace() {
    mkdir -p "$SSH_DIR"
    cat > "$JAILBOX_WORKSPACE" <<EOF_WORKSPACE
{
  "folders": [
    {
      "uri": "vscode-remote://ssh-remote+$CONTAINER_NAME$REMOTE_PATH"
    }
  ],
  "settings": {
    "remote.SSH.configFile": "$SSH_CONFIG"
  }
}
EOF_WORKSPACE
    chmod 600 "$JAILBOX_WORKSPACE"
}

write_jailbox_editor_user_settings() {
    mkdir -p "$(dirname "$JAILBOX_EDITOR_USER_SETTINGS")"
    cat > "$JAILBOX_EDITOR_USER_SETTINGS" <<EOF_SETTINGS
{
  "remote.SSH.configFile": "$SSH_CONFIG"
}
EOF_SETTINGS
    chmod 600 "$JAILBOX_EDITOR_USER_SETTINGS"
}

doctor_jailbox() {
    echo "Project jailbox state: $SSH_DIR"
    if [ -d "$SSH_DIR" ]; then
        echo ".jailbox exists: yes"
    else
        echo ".jailbox exists: no"
    fi

    if gitignore_has_entry ".jailbox/"; then
        echo ".jailbox gitignored: yes"
    else
        echo ".jailbox gitignored: no"
    fi

    echo "SSH config: $SSH_CONFIG"
    if [ -f "$SSH_CONFIG" ]; then
        echo "ssh_config exists: yes"
    else
        echo "ssh_config exists: no"
    fi

    echo "Current project host alias: $CONTAINER_NAME"
    if [ -f "$SSH_CONFIG" ] && ssh -F "$SSH_CONFIG" -o ConnectTimeout=1 "$CONTAINER_NAME" true 2>/dev/null; then
        echo "Internal SSH works: yes"
    elif [ -f "$SSH_CONFIG" ]; then
        echo "Internal SSH works: no"
    else
        echo "Internal SSH works: no (missing ssh_config)"
    fi

    if [ -f "$JAILBOX_WORKSPACE" ] && editor_config_has_ssh_config "$JAILBOX_WORKSPACE"; then
        echo "Project editor config: .jailbox/jailbox.code-workspace -> .jailbox/ssh_config"
    else
        echo "Project editor config: missing"
    fi

    if [ -f "$JAILBOX_EDITOR_USER_SETTINGS" ] && editor_config_has_ssh_config "$JAILBOX_EDITOR_USER_SETTINGS"; then
        echo "Project-local editor user-data config: yes"
    else
        echo "Project-local editor user-data config: no"
    fi
}
