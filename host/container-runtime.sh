# Read-only mounts, persistent home, cleanup, and container launch.

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
        # Intentionally narrow: protect only the exact .env file, not
        # .env.local, .env.production, .env.*.local, or other Node/Next.js
        # variants that projects may expect to edit during development.
        ".env"
        ".gitea/workflows"
        ".github/workflows"
        "jailbox"
        "jailbox.conf"
    )

    # If jailbox lives inside the project, protect the whole submodule/directory.
    if [[ "$SCRIPT_DIR" == "$PROJECT_DIR/"* ]]; then
        local submodule_rel
        submodule_rel="${SCRIPT_DIR#$PROJECT_DIR/}"
        READONLY_PATHS=("$submodule_rel" "${READONLY_PATHS[@]}")
    fi

    # A configured DEV_CONTAINERFILE is a build input the next launch executes
    # via podman build, exactly like the default candidates above. Protect it
    # when it resolves inside the project; a containerfile outside the project
    # is not reachable through the project mount and needs no overlay.
    if [ -n "$DEV_CONTAINERFILE" ]; then
        local containerfile_abs containerfile_rel
        case "$DEV_CONTAINERFILE" in
            /*) containerfile_abs="$DEV_CONTAINERFILE" ;;
            *)  containerfile_abs="$PROJECT_DIR/$DEV_CONTAINERFILE" ;;
        esac
        containerfile_abs=$(realpath -m -- "$containerfile_abs" 2>/dev/null) || containerfile_abs=""
        if [[ -n "$containerfile_abs" && "$containerfile_abs" == "$PROJECT_DIR/"* ]]; then
            containerfile_rel="${containerfile_abs#"$PROJECT_DIR"/}"
            readonly_paths_contain "$containerfile_rel" || READONLY_PATHS+=("$containerfile_rel")
        fi
    fi

    # READONLY_EXTRA is additive only: project config can extend the protected
    # set but never remove or replace the built-in defaults. Skip entries
    # already in the list so podman never sees duplicate mount destinations.
    local extra
    for extra in "${READONLY_EXTRA[@]}"; do
        readonly_paths_contain "$extra" || READONLY_PATHS+=("$extra")
    done
}

readonly_paths_contain() {
    local path candidate

    candidate="$1"
    for path in "${READONLY_PATHS[@]}"; do
        [ "$path" = "$candidate" ] && return 0
    done
    return 1
}

# A protected path that is absent at launch gets no read-only overlay, so
# anything inside the container could create it — and .env or CI workflow
# files materializing on the host is exactly what the overlays exist to
# prevent. Stub the high-risk entries: empty directories are invisible to git
# and an empty .env is inert. Containerfile candidates are deliberately not
# stubbed; an empty Containerfile would break dev-image discovery.
ensure_readonly_stubs() {
    local stub_dirs stub_files path

    stub_dirs=(".gitea/workflows" ".github/workflows")
    stub_files=(".env")

    for path in "${stub_dirs[@]}"; do
        if [ ! -e "$PROJECT_DIR/$path" ]; then
            mkdir -p "$PROJECT_DIR/$path"
            echo "🔒 Created stub for protected path: $path/"
        fi
    done
    for path in "${stub_files[@]}"; do
        if [ ! -e "$PROJECT_DIR/$path" ]; then
            touch "$PROJECT_DIR/$path"
            echo "🔒 Created stub for protected path: $path"
        fi
    done
}

build_readonly_mounts() {
    local path
    READONLY_MOUNTS=()
    for path in "${READONLY_PATHS[@]}"; do
        [ -e "$PROJECT_DIR/$path" ] && READONLY_MOUNTS+=(-v "$PROJECT_DIR/$path:$REMOTE_PATH/$path:Z,ro")
    done

    # Default paths are skipped silently when absent, but READONLY_EXTRA was
    # requested explicitly — a missing path gets no read-only mount and could
    # be created writable from inside the container, so surface that.
    for path in "${READONLY_EXTRA[@]}"; do
        if [ ! -e "$PROJECT_DIR/$path" ]; then
            echo "⚠️  READONLY_EXTRA path does not exist and is not protected: $path"
        fi
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
        # Rootless volumes are created from the host side. Chown only the new
        # jailbox-managed home volume so the keep-id user can write to it; do
        # not repair ownership inside the project or dev image.
        podman unshare chown "$(id -u):$(id -g)" "$VOLUME_PATH"
    fi
}

start_jailbox_container() {
    if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
        echo "Replacing existing jailbox container: $CONTAINER_NAME"
    fi
    echo "🚢 Starting jailbox..."
    # Keep the runtime non-privileged. SSH auth state is copied into a
    # user-owned runtime directory mounted at /run/jailbox-sshd. Do not make
    # /run itself world-writable: OpenSSH StrictModes rejects that parent path.
    # The public key is mounted only as an inert source file; container/entrypoint.sh
    # copies it into /run/jailbox-sshd with strict ownership before sshd starts.
    podman run -d \
        --name "$CONTAINER_NAME" \
        --replace \
        --userns=keep-id \
        --network "$JAILBOX_NETWORK" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m,noexec \
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
