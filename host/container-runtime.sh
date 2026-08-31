# Read-only mounts, persistent home, cleanup, and container launch.

EFFECTIVE_READONLY_PATHS=()
READONLY_MOUNTS=()
GITCONFIG_MOUNT=()
ROOTFS_FLAG=()

initialize_container_runtime_state() {
    EFFECTIVE_READONLY_PATHS=()
    READONLY_MOUNTS=()
    GITCONFIG_MOUNT=()
    ROOTFS_FLAG=()
}

validate_configured_readonly_paths() {
    local path
    for path in "${READONLY_PATHS[@]}"; do
        check_readonly_path "$path" >/dev/null
    done
}

effective_readonly_contains() {
    local candidate path
    candidate="$1"
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        [ "$path" = "$candidate" ] && return 0
    done
    return 1
}

finalize_effective_readonly_paths() {
    local path relative classified status
    local -a automatic_inputs
    EFFECTIVE_READONLY_PATHS=()
    for path in "${READONLY_PATHS[@]}"; do
        status=0
        relative=$(check_readonly_path "$path") || status=$?
        [ "$status" -eq 0 ] || return "$status"
        effective_readonly_contains "$relative" || EFFECTIVE_READONLY_PATHS+=("$relative")
    done
    # The default config is optional, but once observed it and every selected
    # input must still exist at each recheck.
    automatic_inputs=()
    [ "$DEFAULT_CONFIG_PRESENT" -eq 1 ] && automatic_inputs+=("$DEFAULT_CONFIG_INPUT")
    [ -n "$SELECTED_CONFIG_INPUT" ] && automatic_inputs+=("$SELECTED_CONFIG_INPUT")
    [ -n "$SELECTED_DEV_CONTAINERFILE_INPUT" ] && automatic_inputs+=("$SELECTED_DEV_CONTAINERFILE_INPUT")
    for path in "${automatic_inputs[@]}"; do
        status=0
        classified=$(classify_trusted_file "$path" "launch input") || status=$?
        [ "$status" -eq 0 ] || return "$status"
        relative="${classified#*$'\t'}"
        [ -n "$relative" ] || continue
        effective_readonly_contains "$relative" || EFFECTIVE_READONLY_PATHS+=("$relative")
    done
}

build_readonly_mounts() {
    local path status
    # Reassemble from original trusted-input spellings immediately before
    # creating mount arguments so a path replaced with a symlink is rejected.
    status=0
    finalize_effective_readonly_paths || status=$?
    [ "$status" -eq 0 ] || return "$status"
    READONLY_MOUNTS=()
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        READONLY_MOUNTS+=(-v "$PROJECT_DIR/$path:$REMOTE_PATH/$path:Z,ro")
    done
}

configure_runtime_mounts() {
    local gitconfig_file

    GITCONFIG_MOUNT=()
    gitconfig_file="$SSH_DIR/gitconfig"
    generate_minimal_gitconfig "$gitconfig_file"
    [ -f "$gitconfig_file" ] && GITCONFIG_MOUNT=(-v "$gitconfig_file:/home/$MANAGED_USER/.gitconfig:ro")

    # The container root filesystem is always read-only. Project and home
    # writes go through explicit mounts; runtime state uses tmpfs mounts.
    ROOTFS_FLAG=(--read-only)
}

generate_minimal_gitconfig() {
    local gitconfig_file name email tmp_file

    gitconfig_file="$1"
    rm -f -- "$gitconfig_file"
    command -v git >/dev/null 2>&1 || return 0

    name=$(git config --global --get user.name 2>/dev/null || true)
    email=$(git config --global --get user.email 2>/dev/null || true)
    [ -n "$name$email" ] || return 0

    mkdir -p "$(dirname "$gitconfig_file")"
    tmp_file=$(mktemp "$(dirname "$gitconfig_file")/gitconfig.tmp.XXXXXX")
    chmod 600 "$tmp_file"
    [ -n "$name" ] && git config --file "$tmp_file" user.name "$name"
    [ -n "$email" ] && git config --file "$tmp_file" user.email "$email"
    mv "$tmp_file" "$gitconfig_file"
    chmod 600 "$gitconfig_file"
}

assert_container_launch_state() {
    [ -n "$JAILBOX_IMAGE" ] || die "internal error: container launch requires initialized image state"
    [ -n "${NETWORK_STATE[selected_network]}" ] || die "internal error: container launch requires initialized network state"
    [ "${ROOTFS_FLAG[*]-}" = "--read-only" ] || \
        die "internal error: container launch requires read-only rootfs state"
    [ -n "$SSHD_RUNTIME_DIR" ] && [ -d "$SSHD_RUNTIME_DIR" ] || \
        die "internal error: container launch requires initialized SSH runtime state"
    [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE.pub" ] || \
        die "internal error: container launch requires initialized SSH credentials"
    [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && \
        [ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ] || \
        die "internal error: container launch requires a valid SSH port"
    [ -n "$CONTAINER_NAME" ] && [ -n "$VOLUME_NAME" ] || \
        die "internal error: container launch requires initialized resource names"
    [ -n "$PROJECT_DIR" ] && [ -n "$REMOTE_PATH" ] || \
        die "internal error: container launch requires initialized project paths"
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
    local volume_path

    if ! podman volume exists "$VOLUME_NAME" 2>/dev/null; then
        podman volume create --label "jailbox.project=$PROJECT_DIR" "$VOLUME_NAME"
        volume_path=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}')
        # Rootless volumes are created from the host side. Chown only the new
        # jailbox-managed home volume so the keep-id user can write to it; do
        # not repair ownership inside the project or dev image.
        podman unshare chown "$(id -u):$(id -g)" "$volume_path"
    fi
}

start_jailbox_container() {
    assert_container_launch_state

    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        echo "Replacing existing jailbox container: $CONTAINER_NAME"
    fi
    echo "🚢 Starting jailbox..."
    # Keep the runtime non-privileged. SSH auth state is copied into a
    # user-owned runtime directory mounted at /run/jailbox-sshd. Do not make
    # /run itself world-writable: OpenSSH StrictModes rejects that parent path.
    # /tmp is deliberately exec-capable: the home volume and project mount are
    # writable+exec, so noexec on /tmp adds no containment — it only breaks
    # tools that extract native code to the temp dir at runtime (Bun
    # single-file binaries, PyInstaller, .NET single-file, AppImage).
    # The public key is mounted only as an inert source file; container/entrypoint.sh
    # copies it into /run/jailbox-sshd with strict ownership before sshd starts.
    podman run -d \
        --name "$CONTAINER_NAME" \
        --label "jailbox.project=$PROJECT_DIR" \
        --replace \
        --userns=keep-id \
        --network "${NETWORK_STATE[selected_network]}" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m \
        --tmpfs /run:rw,size=64m \
        -v "$SSHD_RUNTIME_DIR:/run/jailbox-sshd:Z" \
        -v "$VOLUME_NAME":/home/$MANAGED_USER \
        "${GITCONFIG_MOUNT[@]}" \
        -p 127.0.0.1:"$LOCAL_PORT":2222 \
        -v "$PROJECT_DIR:$REMOTE_PATH:Z" \
        -v "$KEY_FILE.pub:/etc/ssh/jailbox_authorized_keys.source:ro,Z" \
        "${READONLY_MOUNTS[@]}" \
        --memory=4g \
        --cpus=2 \
        --pids-limit=256 \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$JAILBOX_IMAGE"
}

doctor_jailbox() {
    local container_status container_os_release

    echo "Project jailbox state: $SSH_DIR"
    if [ -d "$SSH_DIR" ]; then
        echo "State directory exists: yes"
    else
        echo "State directory exists: no"
    fi

    if command -v podman >/dev/null 2>&1; then
        container_status=$(podman container inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || true)
        if [ -n "$container_status" ]; then
            echo "Container status: $container_status"
        else
            echo "Container status: missing"
        fi
    else
        container_status=""
        echo "Container status: unknown (podman not found)"
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

    if [ -f "$JAILBOX_EDITOR_USER_SETTINGS" ] && editor_config_has_ssh_config "$JAILBOX_EDITOR_USER_SETTINGS"; then
        echo "Project-local editor user-data config: yes"
    else
        echo "Project-local editor user-data config: no"
    fi

    if [ "$container_status" = "running" ]; then
        container_os_release=$(ssh -F "$SSH_CONFIG" -o ConnectTimeout=1 "$CONTAINER_NAME" \
            "cat /etc/os-release" 2>/dev/null || true)
        # doctor does not run host_preflight, so EDITOR_BIN is usually unset
        # here. editor_profile_uses_code then falls back to command -v checks
        # against the PATH used for this doctor invocation. That is acceptable
        # for a warning: false negatives are better than blocking doctor, but
        # the warning may not fire if code/codium are absent from PATH now.
        if printf '%s\n' "$container_os_release" | grep -Eq '^ID="?alpine"?$' &&
            [ -f "$JAILBOX_EDITOR_USER_SETTINGS" ] &&
            editor_config_has_ssh_config "$JAILBOX_EDITOR_USER_SETTINGS" &&
            editor_profile_uses_code; then
            echo "Warning: VS Code Remote SSH does not support Alpine SSH hosts; set EDITOR=codium in jailbox.conf."
        fi
    fi
}
