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
    UP_CONVERGING=false
}

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
            # A sentinel preserves newlines for exact validation. Required
            # producer failure remains failure even with plausible stdout.
            running=$(podman container inspect "$CONTAINER_NAME" \
                --format '{{.State.Running}}' 2>/dev/null && printf '.') || \
                die "could not inspect development container state"
            case "$running" in
                $'true\n.') result=running ;;
                $'false\n.') ;;
                *) die "invalid development container state inspection" ;;
            esac
        fi
    done
    printf '%s\n' "$result"
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

# Read the fixed-width digest label, rejecting extra bytes inside the engine
# before command substitution can strip trailing newlines. An absent label
# stays empty; inspection failure remains an operational error.
jailbox_resource_label() {
    local kind name label

    kind="$1"
    name="$2"
    label="$3"
    case "$kind" in
        container)
            podman container inspect "$name" \
                --format '{{with index .Config.Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
            ;;
        volume)
            podman volume inspect "$name" \
                --format '{{with index .Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
            ;;
        network)
            podman network inspect "$name" \
                --format '{{with index .Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
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
                die "home '$VOLUME_NAME' is an orphaned ephemeral home; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up'"
            [ "$EPHEMERAL_HOME" = true ] || \
                die "home '$VOLUME_NAME' is ephemeral; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up' to change to persistent"
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
        if [[ "$target" = "volume:$VOLUME_NAME" && "$policy" != true ]]; then
            continue
        fi
        removable+=("$target")
    done
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
    echo "🛑 Stopping jailbox..."
    for target in "${removable[@]}"; do
        remove_project_resource "$target"
    done
    remove_ssh_generation || return 1
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

generate_minimal_gitconfig() (
    # This scope owns only its staging file; launch rollback owns published files.
    local gitconfig_file name email tmp_file="" parent
    trap 'status=$?; if [ -n "$tmp_file" ]; then
        rm -f -- "$tmp_file" || { echo "Error: could not clean temporary Git identity: $tmp_file" >&2; [ "$status" -ne 0 ] || status=1; }
    fi; exit "$status"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    gitconfig_file="$1"
    command -v git >/dev/null 2>&1 || return 0

    # Host identity discovery is intentionally best-effort, including unreadable
    # or malformed global configuration. Writing an available identity below is
    # required preparation and must succeed before it can be mounted.
    name=$(git config --global --get user.name 2>/dev/null || true)
    email=$(git config --global --get user.email 2>/dev/null || true)
    [ -n "$name$email" ] || return 0

    # New parent directories are private too; leave existing parents unchanged.
    parent=$(dirname "$gitconfig_file") || return 1
    (umask 077; mkdir -p -- "$parent") || return 1
    tmp_file=$(mktemp "$parent/gitconfig.tmp.XXXXXX") || return 1
    chmod 600 "$tmp_file" || return 1
    if [ -n "$name" ]; then
        git config --file "$tmp_file" user.name "$name" || return 1
    fi
    if [ -n "$email" ]; then
        git config --file "$tmp_file" user.email "$email" || return 1
    fi
    mv "$tmp_file" "$gitconfig_file" || return 1
    tmp_file=""
)

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
    local volume_path uid gid
    local -a present=()

    resolve_present_resources present "volume:$VOLUME_NAME" || return 1
    if [ -z "${present[*]-}" ]; then
        podman volume create --label "jailbox.ephemeral-home=$EPHEMERAL_HOME" "$VOLUME_NAME" || return 1
        volume_path=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}') || return 1
        # Rootless volumes are created from the host side. Chown only the new
        # jailbox-managed home volume so the keep-id user can write to it; do
        # not repair ownership inside the project or dev image.
        uid=$(id -u) || return 1
        gid=$(id -g) || return 1
        podman unshare chown "$uid:$gid" "$volume_path" || return 1
    fi
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
        "${CONFIG_DIGEST_LABEL_ARGS[@]}" \
        --userns=keep-id \
        --network "${NETWORK_STATE[selected_network]}" \
        "${ROOTFS_FLAG[@]}" \
        --tmpfs /tmp:rw,size=512m \
        --mount type=tmpfs,destination=/run,tmpfs-size=64m,tmpfs-mode=0700,U=true \
        -v "$SSHD_RUNTIME_DIR:/run/jailbox-sshd:ro,Z" \
        -v "$VOLUME_NAME":/home/$MANAGED_USER \
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

# Armed after compatibility inspection, before the first sandbox mutation.
rollback_ssh_launch() {
    [ "$1" -eq 0 ] || rollback_up_launch
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

# One invocation's immutable inventory and attempted creations. No labels or
# names supplied by the sandbox are used as associative-array subscripts.
UP_PRESENT=()
UP_CREATED=()
UP_HOST_CREATED=()
UP_DEV_STATE=absent
UP_PROXY_STATE=absent
UP_CONVERGING=false

begin_up_convergence() {
    UP_CONVERGING=true
}

fail_sandbox_readiness() {
    die "sandbox convergence failed after startup or synchronization began: $*. Sandbox state may have changed; cleanup and retained-resource reporting follow."
}

resume_jailbox_container() {
    podman start "$CONTAINER_NAME" || fail_sandbox_readiness "could not start development container '$CONTAINER_NAME'"
}

up_resource_present() {
    local target
    for target in "${UP_PRESENT[@]}"; do
        [ "$target" != "$1" ] || return 0
    done
    return 1
}

track_up_resource() {
    up_resource_present "$1" || UP_CREATED+=("$1")
    return 0
}

up_stop_guidance() {
    local policy=false probe=0
    jailbox_resource_exists volume "$VOLUME_NAME" || probe=$?
    case "$probe" in
        0) policy=$(home_retention_policy) || return 1 ;;
        1) ;;
        *) printf 'Could not inspect home retention; resolve the engine error before choosing recovery.\n' >&2; return 1 ;;
    esac
    printf "Run 'jailbox stop' then 'jailbox up'. Stop removes containers, networks and SSH credentials; "
    case "$policy" in
        true) printf 'it deletes the recorded ephemeral home.\n' ;;
        *) printf 'it preserves the persistent home.\n' ;;
    esac
}

refuse_sandbox() {
    local guidance
    if [ "$UP_CONVERGING" = true ]; then
        fail_sandbox_readiness "$@"
    fi
    guidance=$(up_stop_guidance) || return 1
    die "refusing sandbox reuse: $*. $guidance"
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

inspect_sandbox_for_up() {
    local path
    UP_CREATED=()
    UP_HOST_CREATED=()
    resolve_present_resources UP_PRESENT \
        "container:$CONTAINER_NAME" "container:$PROXY_NAME" \
        "network:$NETWORK_NAME" "network:${NETWORK_NAME}-internal" \
        "network:${NETWORK_NAME}-external" "volume:$VOLUME_NAME"
    UP_DEV_STATE=$(inspect_up_container_state "$CONTAINER_NAME")
    UP_PROXY_STATE=$(inspect_up_container_state "$PROXY_NAME")
    inspect_network_for_up
    validate_ssh_state_path || return 1
    if [ -d "$SSH_DIR" ]; then
        validate_ssh_file "$SSH_DIR" 700 directory || \
            die "runtime directory '$SSH_DIR' must be owned by UID $(id -u) with mode 700; correct its metadata before retrying up"
    fi
    for path in "$SSH_DIR/gitconfig" "$SSH_DIR/tinyproxy-filter" "$SSH_DIR/tinyproxy.conf"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            [[ -f "$path" && ! -L "$path" ]] || \
                die "unsafe runtime file '$path'; replace it with a regular file or remove it before retrying up (stop preserves unrelated runtime files)"
        fi
    done
    if [ "$UP_DEV_STATE" = absent ]; then
        require_ssh_generation_absent || { up_stop_guidance >&2; return 1; }
    else
        up_resource_present "volume:$VOLUME_NAME" || refuse_sandbox 'development container has no home volume'
        validate_ssh_resume || { up_stop_guidance >&2; return 1; }
    fi
    # Selection is needed before effective protected mounts can be inspected.
    if [ -z "$DEV_IMAGE" ]; then select_dev_containerfile_for_launch; fi
    finalize_effective_readonly_paths
    validate_sandbox_structure
}

# Templates compare untrusted paths inside the engine; their bytes never form
# shell records or executable expressions. Only a literal true is accepted.
require_container_property() {
    local result
    result=$(podman container inspect "$1" --format "$2") || die "could not inspect $3 on '$1'"
    [ "$result" = true ] || refuse_sandbox "$3 on '$1' is incompatible"
}

validate_container_hardening() {
    local name="$1"
    require_container_property "$name" \
        '{{and .HostConfig.ReadonlyRootfs (not .HostConfig.Privileged) (eq (len .EffectiveCaps) 0) (eq (len .BoundingCaps) 0) (eq (len .HostConfig.CapAdd) 0) (eq (len .HostConfig.Devices) 0)}}' 'runtime hardening'
    require_container_property "$name" \
        '{{range .HostConfig.SecurityOpt}}{{if or (eq . "no-new-privileges") (eq . "no-new-privileges=true")}}true{{end}}{{end}}' 'no-new-privileges'
    require_container_property "$name" \
        '{{and (or (eq .HostConfig.PidMode "") (eq .HostConfig.PidMode "private")) (or (eq .HostConfig.IpcMode "") (eq .HostConfig.IpcMode "private") (eq .HostConfig.IpcMode "shareable")) (or (eq .HostConfig.UTSMode "") (eq .HostConfig.UTSMode "private")) (ne .HostConfig.NetworkMode "host") (eq .Pod "")}}' 'namespace isolation'
    # shellcheck disable=SC2016  # Go template variables, not shell expansions.
    require_container_property "$name" \
        '{{if eq (len .HostConfig.Tmpfs) 2}}{{range $path, $options := .HostConfig.Tmpfs}}{{if not (or (eq $path "/tmp") (eq $path "/run"))}}invalid{{end}}{{end}}true{{end}}' 'tmpfs mount inventory'
}

require_container_mount() {
    local name="$1" destination="$2" kind="$3" source="$4" rw="$5" predicate
    predicate="(and (eq .Type $(ssh_inspect_quote "$kind")) (eq .RW $rw)"
    if [ "$kind" = volume ]; then
        predicate+=" (eq .Name $(ssh_inspect_quote "$source")))"
    else
        predicate+=" (eq .Source $(ssh_inspect_quote "$source")))"
    fi
    require_container_property "$name" \
        "{{range .Mounts}}{{if eq .Destination $(ssh_inspect_quote "$destination")}}{{$predicate}}{{end}}{{end}}" "mount '$destination'"
}

validate_development_mounts() {
    local path template allowed
    require_container_mount "$CONTAINER_NAME" "$REMOTE_PATH" bind "$PROJECT_DIR" true
    require_container_mount "$CONTAINER_NAME" "/home/$MANAGED_USER" volume "$VOLUME_NAME" true
    validate_ssh_container_mount || return 1
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        require_container_mount "$CONTAINER_NAME" "$REMOTE_PATH/$path" bind "$PROJECT_DIR/$path" false
    done
    # Reject additional mounts, including overlays below protected mounts and
    # host socket aliases. Only jailbox's explicit mount inventory is eligible.
    allowed="(or (eq .Destination $(ssh_inspect_quote "$REMOTE_PATH")) (eq .Destination $(ssh_inspect_quote "/home/$MANAGED_USER")) (eq .Destination \"/run/jailbox-sshd\")"
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        allowed+=" (eq .Destination $(ssh_inspect_quote "$REMOTE_PATH/$path"))"
    done
    allowed+=" (and (eq .Destination $(ssh_inspect_quote "/home/$MANAGED_USER/.gitconfig")) (eq .Type \"bind\") (not .RW) (eq .Source $(ssh_inspect_quote "$SSH_DIR/gitconfig"))))"
    template="{{range .Mounts}}{{if not $allowed}}invalid{{end}}{{end}}true"
    require_container_property "$CONTAINER_NAME" "$template" 'mount inventory'
    require_container_property "$CONTAINER_NAME" \
        "{{if eq (len .HostConfig.PortBindings) 1}}{{range \$port, \$bindings := .HostConfig.PortBindings}}{{if and (eq \$port \"2222/tcp\") (eq (len \$bindings) 1)}}{{range \$bindings}}{{and (eq .HostIP \"127.0.0.1\") (eq .HostPort $(ssh_inspect_quote "$LOCAL_PORT"))}}{{end}}{{end}}{{end}}{{end}}" 'SSH port publication'
}

validate_sandbox_structure() {
    local name present=()
    resolve_present_resources present "container:$CONTAINER_NAME" "container:$PROXY_NAME"
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        [[ " ${present[*]} " == *" container:$name "* ]] || continue
        validate_container_hardening "$name"
        validate_container_networks "$name"
        if [ "$name" = "$CONTAINER_NAME" ]; then
            validate_development_mounts
        else
            validate_proxy_configuration
        fi
    done
}

configure_runtime_mounts() {
    local path
    validate_ssh_state_path || return 1
    if [ ! -d "$SSH_DIR" ]; then
        UP_HOST_CREATED+=("$SSH_DIR")
        # New parent directories are private too; leave existing parents unchanged.
        (umask 077; mkdir -p -- "$SSH_DIR") || return 1
    fi
    validate_ssh_file "$SSH_DIR" 700 directory || refuse_sandbox 'unsafe runtime directory metadata'
    # Existing unrelated runtime files are preserved, including gitconfig.
    GITCONFIG_MOUNT=()
    path="$SSH_DIR/gitconfig"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        UP_HOST_CREATED+=("$path")
        generate_minimal_gitconfig "$path" || return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        [[ -f "$path" && ! -L "$path" ]] || die 'unsafe runtime gitconfig'
        GITCONFIG_MOUNT=(-v "$path:/home/$MANAGED_USER/.gitconfig:ro")
    fi
    ROOTFS_FLAG=(--read-only)
    UP_HOST_CREATED+=("$SSH_GENERATION_DIR")
}

rollback_up_launch() {
    local target kind name probe failed=false dependent=false state path index
    local dev_retained=false proxy_retained=false needed
    # Never stop a survivor. If removal fails, preserve all potentially needed
    # dependencies and authentication, even when the survivor is stopped.
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        for target in "${UP_CREATED[@]}"; do
            [ "$target" = "container:$name" ] || continue
            if [ "$name" = "$PROXY_NAME" ]; then
                probe=0
                jailbox_resource_exists container "$CONTAINER_NAME" || probe=$?
                if [ "$probe" -ne 1 ]; then
                    printf "Retained dependency '%s' for surviving development container.\n" "$name" >&2
                    continue
                fi
            fi
            probe=0
            jailbox_resource_exists container "$name" || probe=$?
            [ "$probe" -ne 1 ] || continue
            if [ "$probe" -ne 0 ] || ! podman rm -f "$name"; then
                failed=true
                printf "Error: cleanup could not remove '%s'; dependencies retained.\n" "$name" >&2
            fi
        done
    done
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        probe=0
        jailbox_resource_exists container "$name" || probe=$?
        [ "$probe" -eq 1 ] || dependent=true
        if [ "$probe" -ne 1 ]; then
            if [ "$name" = "$CONTAINER_NAME" ]; then dev_retained=true; else proxy_retained=true; fi
        fi
        if [ "$probe" -eq 0 ]; then
            state=$(podman container inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || state=unknown
            printf "Retained container '%s': %s.\n" "$name" "$state" >&2
        fi
    done
    for ((index=${#UP_CREATED[@]}-1; index>=0; index--)); do
        target=${UP_CREATED[index]}
        kind=${target%%:*}; name=${target#*:}
        [ "$kind" != container ] || continue
        needed=$dependent
        [ "$kind" != volume ] || needed=$dev_retained
        if [ "$needed" = true ]; then
            printf "Retained dependency '%s'.\n" "$target" >&2
            continue
        fi
        probe=0
        jailbox_resource_exists "$kind" "$name" || probe=$?
        [ "$probe" -ne 1 ] || continue
        if [ "$probe" -ne 0 ] || ! podman "$kind" rm "$name"; then
            failed=true
            printf "Error: cleanup retained '%s'.\n" "$target" >&2
        fi
    done
    for ((index=${#UP_HOST_CREATED[@]}-1; index>=0; index--)); do
        path=${UP_HOST_CREATED[index]}
        needed=$dev_retained
        case "$path" in
            "$SSH_DIR") needed=$dependent ;;
            "$SSH_DIR/tinyproxy-filter"|"$SSH_DIR/tinyproxy.conf") needed=$proxy_retained ;;
        esac
        if [ "$needed" = true ]; then
            printf "Retained launch material '%s' needed by a surviving container.\n" "$path" >&2
        elif [ "$path" = "$SSH_DIR" ]; then
            rmdir "$path" 2>/dev/null || true
        elif ! rm -rf -- "$path"; then
            failed=true
            printf "Error: cleanup retained host material '%s'.\n" "$path" >&2
        fi
    done
    up_stop_guidance >&2 || true
    [ "$failed" = false ]
}
