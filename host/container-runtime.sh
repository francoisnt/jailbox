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

# Exact deterministic names are this project's identity. Podman exposes
# existence and labels differently per resource type, so probing is
# type-specific while the decision made from it is not.
jailbox_resource_exists() {
    case "$1" in
        container) podman container exists "$2" 2>/dev/null ;;
        volume) podman volume exists "$2" 2>/dev/null ;;
        network) podman network exists "$2" 2>/dev/null ;;
        image) podman image exists "$2" 2>/dev/null ;;
        *) die "internal error: unknown jailbox resource type '$1'" ;;
    esac
}

# Read one label from a resource. An unreadable resource, a resource carrying
# no labels, and an absent label all report the empty value, so every caller
# decides in the fail-closed direction. Label names come from jailbox's own
# declarations, never from user input.
jailbox_resource_label() {
    local kind name label

    kind="$1"
    name="$2"
    label="$3"
    case "$kind" in
        container)
            podman container inspect "$name" \
                --format '{{ index .Config.Labels "'"$label"'" }}' 2>/dev/null || true
            ;;
        volume)
            podman volume inspect "$name" \
                --format '{{ index .Labels "'"$label"'" }}' 2>/dev/null || true
            ;;
        network)
            podman network inspect "$name" \
                --format '{{ index .Labels "'"$label"'" }}' 2>/dev/null || true
            ;;
        *) die "internal error: unknown jailbox resource type '$kind'" ;;
    esac
}

# Resolve "TYPE:NAME" targets into the present removal set named by the first
# argument. Every target is probed before anything is removed, so a Podman
# probe failure aborts the whole operation with nothing mutated.
#
# Presence under the derived name is the only test. Deletion deliberately does
# not consult the configuration digest: stop and --clean stay usable when
# configuration is missing or malformed, so an occupant of a derived name is
# removed whatever created it.
resolve_present_resources() {
    local -n present_ref="$1"
    shift
    local target kind name status

    present_ref=()
    for target in "$@"; do
        kind="${target%%:*}"
        name="${target#*:}"
        status=0
        jailbox_resource_exists "$kind" "$name" || status=$?
        case "$status" in
            0) present_ref+=("$target") ;;
            1) ;;
            *) die "could not determine whether $kind '$name' exists with Podman" ;;
        esac
    done
}

remove_project_resource() {
    local kind name removal_status=0 probe_status=0

    kind="${1%%:*}"
    name="${1#*:}"
    case "$kind" in
        container)
            podman stop "$name" 2>/dev/null || true
            podman rm "$name" || removal_status=$?
            ;;
        volume|network|image)
            podman "$kind" rm "$name" || removal_status=$?
            ;;
    esac
    [ "$removal_status" -ne 0 ] || return 0
    # A target may disappear after preflight. Accept confirmed absence, but
    # never treat a failed recheck as absence or parse engine error wording.
    jailbox_resource_exists "$kind" "$name" || probe_status=$?
    [ "$probe_status" -eq 1 ] || \
        die "could not remove $kind '$name' or confirm its absence; retry the cleanup after resolving the error"
}

# Classify inside the template: arbitrary label bytes (including trailing
# newlines) must never become valid through shell command substitution. An
# absent key, a present empty value, and failed inspection stay distinct.
home_retention_policy() {
    local policy

    policy=$(podman volume inspect "$VOLUME_NAME" --format \
        '{{range $key, $value := .Labels}}{{if eq $key "jailbox.ephemeral-home"}}{{if eq $value "true"}}true{{else if eq $value "false"}}false{{else}}corrupt{{end}}{{end}}{{end}}') || \
        die "could not inspect retention metadata for home '$VOLUME_NAME'; no resources were changed"
    case "$policy" in
        "") printf 'false\n' ;;
        true|false|corrupt) printf '%s\n' "$policy" ;;
        *) die "unexpected home retention inspection result for '$VOLUME_NAME'" ;;
    esac
}

home_clean_guidance() {
    printf "Run 'jailbox --clean' and then 'jailbox up'; --clean permanently deletes this project's home and runtime state."
}

require_compatible_home() {
    local policy
    local -a present=()

    # Current dispatch requires absent containers. Keep the generation-aware
    # check here for constrained up (03.2.06), which removes that blanket guard
    # and owns CLI convergence verification for surviving containers.
    resolve_present_resources present "volume:$VOLUME_NAME" "container:$CONTAINER_NAME"
    [[ " ${present[*]} " == *" volume:$VOLUME_NAME "* ]] || return 0
    policy=$(home_retention_policy) || return $?
    case "$policy" in
        corrupt)
            die "home '$VOLUME_NAME' has corrupt retention metadata; refusing reuse. $(home_clean_guidance)"
            ;;
        false)
            [ "$EPHEMERAL_HOME" = false ] || \
                die "home '$VOLUME_NAME' is persistent; refusing a change to ephemeral. $(home_clean_guidance)"
            ;;
        true)
            [[ " ${present[*]} " == *" container:$CONTAINER_NAME "* ]] || \
                die "home '$VOLUME_NAME' is an orphaned ephemeral home; run 'jailbox stop' and then 'jailbox up'"
            [ "$EPHEMERAL_HOME" = true ] || \
                die "home '$VOLUME_NAME' is ephemeral; run 'jailbox stop' and then 'jailbox up' to change to persistent"
            ;;
    esac
}

require_sandbox_absent() {
    local name status

    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        status=0
        jailbox_resource_exists container "$name" || status=$?
        case "$status" in
            0)
                die "project sandbox container '$name' is still present; run 'jailbox stop' to remove it"
                ;;
            1) ;;
            *) die "could not determine whether container '$name' exists with Podman" ;;
        esac
    done
}

# Determine retention before mutation, then remove containers, networks, and
# finally an ephemeral home. A failed or interrupted removal remains retryable.
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
        if [ "$target" = "volume:$VOLUME_NAME" ] && [ "$policy" != true ]; then
            continue
        fi
        removable+=("$target")
    done
    if [ -z "${removable[*]-}" ]; then
        echo "No jailbox resources to stop."
        return 0
    fi
    echo "🛑 Stopping jailbox..."
    for target in "${removable[@]}"; do
        remove_project_resource "$target"
    done
    echo "✅ Stopped"
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
    # Launch requires the default config, so a finalized launch set always
    # contains it. The presence flag still gates the non-launch callers that
    # finalize without one. Every observed input must exist at each recheck.
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
    assert_config_digest_ready
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

ensure_home_volume() {
    local volume_path
    local -a present=()

    resolve_present_resources present "volume:$VOLUME_NAME"
    if [ -z "${present[*]-}" ]; then
        podman volume create --label "jailbox.ephemeral-home=$EPHEMERAL_HOME" "$VOLUME_NAME"
        volume_path=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}')
        # Rootless volumes are created from the host side. Chown only the new
        # jailbox-managed home volume so the keep-id user can write to it; do
        # not repair ownership inside the project or dev image.
        podman unshare chown "$(id -u):$(id -g)" "$volume_path"
    fi
}

start_jailbox_container() {
    assert_container_launch_state

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
        "${CONFIG_DIGEST_LABEL_ARGS[@]}" \
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
        --memory="$MEMORY_LIMIT" \
        --cpus="$CPU_LIMIT" \
        --pids-limit="$PIDS_LIMIT" \
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
