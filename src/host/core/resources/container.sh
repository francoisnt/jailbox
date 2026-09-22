# Container observation, structure, mounts, and explicit start operations.

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
        check_readonly_path "$path" >/dev/null || return 1
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
    automatic_inputs=()
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

assert_container_launch_state() {
    assert_config_digest_ready
    [ -n "$JAILBOX_IMAGE" ] || die "internal error: container launch requires initialized image state"
    [ -n "${NETWORK_STATE[selected_network]}" ] || die "internal error: container launch requires initialized network state"
    [ "${ROOTFS_FLAG[*]-}" = "--read-only" ] || \
        die "internal error: container launch requires read-only rootfs state"
    [[ -n "$SSHD_RUNTIME_DIR" && -d "$SSHD_RUNTIME_DIR" ]] || \
        die "internal error: container launch requires initialized SSH runtime state"
    [[ -n "$KEY_FILE" && -f "$SSHD_RUNTIME_DIR/authorized_keys" ]] || \
        die "internal error: container launch requires initialized SSH credentials"
    [[ "$LOCAL_PORT" =~ ^[0-9]+$ &&
        "$LOCAL_PORT" -ge 1 && "$LOCAL_PORT" -le 65535 ]] || \
        die "internal error: container launch requires a valid SSH port"
    [[ -n "$CONTAINER_NAME" && -n "$VOLUME_NAME" ]] || \
        die "internal error: container launch requires initialized resource names"
    [[ -n "$PROJECT_DIR" && -n "$REMOTE_PATH" ]] || \
        die "internal error: container launch requires initialized project paths"
}

start_jailbox_container() {
    assert_container_launch_state

    echo "🚢 Starting jailbox..."
    # Authentication files are prepared on the host and mounted read-only.
    # /run stays private to the managed UID and contains only mutable daemon
    # state alongside the immutable authentication mount. For tmpfs, U=true
    # asks Podman to set mount ownership to the container user.
    # /tmp is deliberately exec-capable: the home volume and project mount are
    # writable+exec, so noexec on /tmp adds no containment — it only breaks
    # tools that extract native code to the temp dir at runtime (Bun
    # single-file binaries, PyInstaller, .NET single-file, AppImage).
    podman run -d \
        --name "$CONTAINER_NAME" \
        --cidfile "$SSH_GENERATION_DIR/container-id" \
        --http-proxy=false \
        --env "JAILBOX_SSH_PROXY_URL=${NETWORK_STATE[proxy_url]}" \
        "${CONFIG_DIGEST_LABEL_ARGS[@]}" \
        --userns=keep-id \
        --network "${NETWORK_STATE[selected_network]}" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m \
        --mount type=tmpfs,destination=/run,tmpfs-size=64m,tmpfs-mode=0700,U=true \
        -v "$SSHD_RUNTIME_DIR:/run/jailbox-sshd:ro,Z" \
        -v "$VOLUME_NAME:/home/$MANAGED_USER" \
        "${GITCONFIG_MOUNT[@]}" \
        -p 127.0.0.1:"$LOCAL_PORT":2222 \
        -v "$PROJECT_DIR:$REMOTE_PATH:Z" \
        "${READONLY_MOUNTS[@]}" \
        --memory="$MEMORY_LIMIT" \
        --cpus="$CPU_LIMIT" \
        --pids-limit="$PIDS_LIMIT" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$JAILBOX_IMAGE"
}

resume_jailbox_container() {
    podman start "$CONTAINER_NAME" || fail_sandbox_readiness "could not start development container '$CONTAINER_NAME'"
}

inspect_up_container_state() {
    local state
    if ! up_resource_present "container:$1"; then printf 'absent\n'; return 0; fi
    state=$(podman container inspect "$1" --format '{{.State.Status}}') || die "could not inspect state of '$1'"
    case "$state" in
        running|exited|stopped|created|configured) printf '%s\n' "$state" ;;
        *) refuse_sandbox "container '$1' has unsupported state '$state'" ;;
    esac
}

# Templates compare untrusted paths inside the engine; their bytes never form
# shell records or executable expressions. Only a literal true is accepted.
require_container_property() {
    local result
    result=$(podman container inspect "$1" --format "$2") || die "could not inspect $3 on '$1'"
    [ "$result" = true ] || refuse_sandbox "$3 on '$1' is incompatible"
}

# Each predicate emits only comparison results, never resource data. A separator
# terminates each result; the sentinel preserves framing through substitution.
require_container_properties() {
    local name="$1" template='' result predicate message line
    shift
    local -a messages=()
    while (($#)); do
        predicate=$1; message=$2; shift 2
        template+="$predicate"'{{printf "|"}}'
        messages+=("$message")
    done
    result=$(podman container inspect "$name" --format "$template" && printf '.') || die "could not inspect container properties on '$name'"
    # Podman terminates the complete formatted record with a newline.
    [[ "$result" = *$'\n.' ]] || die "invalid container property inspection on '$name'"
    result=${result%$'\n.'}
    for message in "${messages[@]}"; do
        [[ "$result" = *'|'* ]] || die "incomplete container property inspection on '$name'"
        line=${result%%|*}
        result=${result#*|}
        if [[ "$line" != true ]]; then
            refuse_sandbox "$message on '$name' is incompatible"
            return 1
        fi
    done
    [[ -z "$result" ]] || die "extra container property inspection output on '$name'"
}

validate_container_hardening() {
    local name="$1"
    # shellcheck disable=SC2016  # Go template variables, not shell expansions.
    require_container_properties "$name" \
        '{{and .HostConfig.ReadonlyRootfs (not .HostConfig.Privileged) (eq (len .EffectiveCaps) 0) (eq (len .BoundingCaps) 0) (eq (len .HostConfig.CapAdd) 0) (eq (len .HostConfig.Devices) 0)}}' 'runtime hardening' \
        '{{range .HostConfig.SecurityOpt}}{{if or (eq . "no-new-privileges") (eq . "no-new-privileges=true")}}true{{end}}{{end}}' 'no-new-privileges' \
        '{{and (or (eq .HostConfig.PidMode "") (eq .HostConfig.PidMode "private")) (or (eq .HostConfig.IpcMode "") (eq .HostConfig.IpcMode "private") (eq .HostConfig.IpcMode "shareable")) (or (eq .HostConfig.UTSMode "") (eq .HostConfig.UTSMode "private")) (ne .HostConfig.NetworkMode "host") (eq .Pod "")}}' 'namespace isolation' \
        '{{if eq (len .HostConfig.Tmpfs) 2}}{{range $path, $options := .HostConfig.Tmpfs}}{{if not (or (eq $path "/tmp") (eq $path "/run"))}}invalid{{end}}{{end}}true{{end}}' 'tmpfs mount inventory'
}

container_mount_predicate() {
    local destination="$1" kind="$2" source="$3" rw="$4" predicate
    predicate="(and (eq .Type $(ssh_inspect_quote "$kind")) (eq .RW $rw)"
    if [ "$kind" = volume ]; then
        predicate+=" (eq .Name $(ssh_inspect_quote "$source")))"
    else
        predicate+=" (eq .Source $(ssh_inspect_quote "$source")))"
    fi
    printf '%s' "{{range .Mounts}}{{if eq .Destination $(ssh_inspect_quote "$destination")}}{{$predicate}}{{end}}{{end}}"
}

require_container_mount() {
    local predicate
    predicate=$(container_mount_predicate "$2" "$3" "$4" "$5") || return 1
    require_container_property "$1" "$predicate" "mount '$2'"
}

validate_development_mounts() {
    local path template allowed
    local -a properties=()
    template=$(container_mount_predicate "$REMOTE_PATH" bind "$PROJECT_DIR" true) || return 1
    properties+=("$template" "mount '$REMOTE_PATH'")
    template=$(container_mount_predicate "/home/$MANAGED_USER" volume "$VOLUME_NAME" true) || return 1
    properties+=("$template" "mount '/home/$MANAGED_USER'")
    require_container_properties "$CONTAINER_NAME" "${properties[@]}" || return 1
    validate_ssh_container_mount || return 1
    properties=()
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        template=$(container_mount_predicate "$REMOTE_PATH/$path" bind "$PROJECT_DIR/$path" false) || return 1
        properties+=("$template" "mount '$REMOTE_PATH/$path'")
    done
    # Reject additional mounts, including overlays below protected mounts and
    # host socket aliases. Only jailbox's explicit mount inventory is eligible.
    allowed="(or (eq .Destination $(ssh_inspect_quote "$REMOTE_PATH")) (eq .Destination $(ssh_inspect_quote "/home/$MANAGED_USER")) (eq .Destination \"/run/jailbox-sshd\")"
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        allowed+=" (eq .Destination $(ssh_inspect_quote "$REMOTE_PATH/$path"))"
    done
    allowed+=" (and (eq .Destination $(ssh_inspect_quote "/home/$MANAGED_USER/.gitconfig")) (eq .Type \"bind\") (not .RW) (eq .Source $(ssh_inspect_quote "$SSH_DIR/gitconfig"))))"
    template="{{range .Mounts}}{{if not $allowed}}invalid{{end}}{{end}}true"
    properties+=("$template" 'mount inventory')
    properties+=("{{if eq (len .HostConfig.PortBindings) 1}}{{range \$port, \$bindings := .HostConfig.PortBindings}}{{if and (eq \$port \"2222/tcp\") (eq (len \$bindings) 1)}}{{range \$bindings}}{{and (eq .HostIP \"127.0.0.1\") (eq .HostPort $(ssh_inspect_quote "$LOCAL_PORT"))}}{{end}}{{end}}{{end}}{{end}}" 'SSH port publication')
    require_container_properties "$CONTAINER_NAME" "${properties[@]}"
}

validate_running_development() {
    validate_development_session full
}

check_readonly_mounts() {
    validate_development_session mounts
}

# Inventory observation deliberately does not inspect configuration, health,
# SSH, or compatibility. A present container is running or stopped; failed or
# malformed inspection is an observation error, never a known stopped state.
inspect_container_running() {
    local running
    running=$(podman container inspect "$1" \
        --format '{{.State.Running}}' 2>/dev/null && printf '.') || {
        printf 'Error: could not inspect development container state\n' >&2
        return 1
    }
    case "$running" in
        $'true\n.') printf 'running\n' ;;
        $'false\n.') printf 'stopped\n' ;;
        *) printf 'Error: invalid development container state inspection\n' >&2; return 1 ;;
    esac
}
