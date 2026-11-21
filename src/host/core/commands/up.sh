# NETWORK_STATE is the associative map declared by resources/network.sh.
# shellcheck disable=SC2154
# commands — up

# One launch owns these attempts. Recording precedes mutation, so an entry does
# not prove creation succeeded. Rollback re-observes resources before removing
# anything and preserves dependencies when survivor inspection fails.
LAUNCH_ATTEMPTED_RESOURCES=()
LAUNCH_ATTEMPTED_HOST_PATHS=()
LAUNCH_CONVERGING=false
LAUNCH_RETAIN_HOME=false
LAUNCH_SETUP_ACTIVE=false
LAUNCH_SETUP_TEMP=''
LAUNCH_SETUP_JOB=''
LAUNCH_PREVIOUS_JOB=''
LAUNCH_SETUP_PROVIDER=''
LAUNCH_SETUP_INPUT_FD=''
LAUNCH_SETUP_OUTPUT_FD=''
LAUNCH_FORWARDING=false

run_up() {
    prepare_launch || return $?
    bring_up_sandbox
}

prepare_launch() {
    initialize_project_names || return 1
    require_command podman || return 1
    load_environment_config || return 1
    host_preflight || return 1
    validate_project_boundary || return 1
    initialize_launch_state
}

bring_up_sandbox() {
    local session_mode=full setup_mode=bind setup_generation='' setup_frame=''
    # Start a new operation before inspection; inspection cannot clear attempts.
    reset_launch_attempts
    initialize_runtime_ids || return 1
    validate_configured_readonly_paths || return 1
    # Stored home policy outranks digest incompatibility: stop cannot repair
    # a persistent-to-ephemeral change or corrupt retention metadata.
    require_compatible_home || return 1
    # The digest is the compatibility gate for every policy-bearing resource
    # that outlives a single launch, so it is computed — and every surviving
    # resource checked against it — before anything is built or created.
    capture_forwarding_policy || return 1
    compute_config_digest launch || return 1
    require_compatible_project_resources || return 1
    inspect_sandbox_compatibility || return 1
    validate_forwarding_reuse || return 1
    if [ "$OBSERVED_DEV_STATE" = absent ]; then
        describe_forwarding_policy || return 1
        if [[ -n "$HOME_SETUP_SCRIPT" ]] && ! observed_resource_present "volume:$VOLUME_NAME"; then
            setup_mode=initialize
            setup_frame=$(encode_ssh_command 'jailbox up home setup' "./$HOME_SETUP_SCRIPT") || return 1
        fi
        build_or_select_dev_image || return 1
        validate_dev_image || return 1
        # Classify launch inputs before the wrapper build. Mount construction
        # repeats this to catch subsequent path replacement.
        finalize_project_path_policy mounted || return 1
        build_jailbox_image
    fi
    if [ "$OBSERVED_PROXY_STATE" = absent ]; then
        build_current_proxy_image || return 1
    fi
    validate_existing_sandbox_health || return 1
    check_local_port_available "$OBSERVED_DEV_STATE" || return 1
    # All refusals above are read-only with respect to sandbox resources.
    # Record attempts before mutation so failures inside an engine operation
    # also enter dependency-safe rollback.
    trap 'rollback_launch_on_exit "$?" || true' EXIT
    trap interrupt_launch HUP INT TERM
    begin_launch_convergence
    configure_network || return 1
    if [ "$OBSERVED_DEV_STATE" = absent ]; then
        session_mode=launch
        configure_runtime_mounts || return 1
        create_ssh_generation || return 1
        build_project_mounts "$setup_mode" || return 1
        if ! observed_resource_present "volume:$VOLUME_NAME"; then
            if [[ -n "$setup_frame" ]]; then
                # A new SSH key is generated for this launch before the home
                # exists. Its public half supplies a fresh, non-secret ID.
                setup_generation=$(config_digest_hash < "$KEY_FILE.pub") || return 1
                is_config_digest_value "$setup_generation" || die 'could not derive home setup generation'
                prepare_setup_provider || return 1
            fi
            record_launch_resource_attempt "volume:$VOLUME_NAME"
            create_home_volume "${setup_generation:-plain}" || return $?
        fi
        if [[ -n "$HOST_COMMAND_POLICY" ]]; then
            validate_forwarding_home_storage || return 1
            LAUNCH_FORWARDING=true
            publish_forwarding_policy || return 1
        fi
        record_launch_resource_attempt "container:$CONTAINER_NAME"
        start_jailbox_container || return $?
    elif [ "$OBSERVED_DEV_STATE" != running ]; then
        session_mode=launch
        resume_jailbox_container || return 1
    fi
    wait_for_ssh || return 1
    validate_sandbox_structure || return 1
    # Healthy reuse must not create write probes that change project metadata.
    validate_development_session "$session_mode" || return 1
    validate_proxy_ready || return 1
    configure_downloader_proxy || return $?
    post_start_validation || return 1
    if [[ "$LAUNCH_FORWARDING" = true ]]; then
        start_forwarding || return 1
    fi
    if [[ -n "$setup_generation" ]]; then
        run_home_setup "$setup_frame" "$setup_generation" || return $?
        if [[ "$LAUNCH_FORWARDING" = true ]]; then
            require_forwarding_health ||
                fail_sandbox_readiness 'host forwarding is unavailable after home setup'
        fi
    fi
    echo '✅ Sandbox is ready'
    trap - EXIT HUP INT TERM
}

prepare_setup_provider() {
    [[ -n "$SETUP_INPUT_SCRIPT" ]] || return 0
    # Snapshot the selected program before the development container can
    # write to the project. Its project-local dependencies still need review.
    LAUNCH_SETUP_PROVIDER=$(umask 077; mktemp "$SSH_DIR/.setup-provider.XXXXXXXX") || return 1
    cat -- "$PROJECT_DIR/$SETUP_INPUT_SCRIPT" > "$LAUNCH_SETUP_PROVIDER" || return 1
    require_script_shebang "$LAUNCH_SETUP_PROVIDER" SETUP_INPUT_SCRIPT || return 1
    chmod 700 "$LAUNCH_SETUP_PROVIDER"
}

exec_setup_provider() {
    exec </dev/null >&"$LAUNCH_SETUP_OUTPUT_FD" {LAUNCH_SETUP_INPUT_FD}<&- {LAUNCH_SETUP_OUTPUT_FD}>&- || return 1
    cd -- "$PROJECT_DIR" || return 1
    exec "$LAUNCH_SETUP_PROVIDER"
}

exec_sandbox_setup() {
    exec <&"$LAUNCH_SETUP_INPUT_FD" {LAUNCH_SETUP_INPUT_FD}<&- || return 1
    exec_ssh_command "$1"
}

run_setup_job() {
    local job_type=$1 result=0 previous_flags=$-
    shift
    # The provider can start host children. Bash job control groups them
    # for cancellation. The SSH client stays in the launch process group.
    if [[ "$job_type" = provider ]]; then set -m; else set +m; fi
    # Arm cleanup before starting the job. $! identifies it at the next trap.
    LAUNCH_PREVIOUS_JOB=${!:-}
    LAUNCH_SETUP_JOB=$job_type
    "$@" &
    set +m
    wait "$!" || result=$?
    LAUNCH_SETUP_JOB=''
    [[ "$previous_flags" != *m* ]] || set -m
    return "$result"
}

interrupt_launch() {
    if [[ "$LAUNCH_SETUP_ACTIVE" = true ]]; then
        printf 'Error: home setup was interrupted.\n' >&2
    fi
    exit 1
}

run_home_setup() {
    local frame=$1 generation=$2 record result=0
    LAUNCH_SETUP_ACTIVE=true
    if [[ -n "$LAUNCH_SETUP_PROVIDER" ]]; then
        LAUNCH_SETUP_TEMP=$(umask 077; mktemp "$SSH_DIR/.setup-input.XXXXXXXX") || return 1
        exec {LAUNCH_SETUP_OUTPUT_FD}> "$LAUNCH_SETUP_TEMP" || return 1
        exec {LAUNCH_SETUP_INPUT_FD}< "$LAUNCH_SETUP_TEMP" || return 1
        # The descriptors retain the file. There is no pathname once any
        # provider output can reach it, even after an unhandled interruption.
        rm -f -- "$LAUNCH_SETUP_TEMP" || return 1
        LAUNCH_SETUP_TEMP=''
        run_setup_job provider exec_setup_provider || result=$?
        exec {LAUNCH_SETUP_OUTPUT_FD}>&-
        LAUNCH_SETUP_OUTPUT_FD=''
        if ((result != 0)); then
            printf 'Error: SETUP_INPUT_SCRIPT failed (exit %d).\n' "$result" >&2
            return "$result"
        fi
    else
        exec {LAUNCH_SETUP_INPUT_FD}< /dev/null || return 1
    fi
    # From here on the sandbox script may have written into the home.
    [[ "$EPHEMERAL_HOME" = true ]] || LAUNCH_RETAIN_HOME=true
    run_setup_job ssh exec_sandbox_setup "$frame" || result=$?
    exec {LAUNCH_SETUP_INPUT_FD}<&-
    LAUNCH_SETUP_INPUT_FD=''
    if ((result != 0)); then
        printf 'Error: HOME_SETUP_SCRIPT failed (exit %d).\n' "$result" >&2
        return "$result"
    fi
    if [[ -n "$LAUNCH_SETUP_PROVIDER" ]]; then
        rm -f -- "$LAUNCH_SETUP_PROVIDER" || return 1
        LAUNCH_SETUP_PROVIDER=''
    fi
    record=$(home_setup_record_path) || return 1
    [[ ! -L "$record" && ! -d "$record" ]] || die 'unsafe home setup completion path'
    LAUNCH_SETUP_TEMP=$(umask 077; mktemp "$SSH_DIR/.home-setup-complete.XXXXXXXX") || return 1
    printf '%s\n' "$generation" > "$LAUNCH_SETUP_TEMP" || return 1
    mv -f -- "$LAUNCH_SETUP_TEMP" "$record" || return $?
    LAUNCH_SETUP_TEMP=''
}

configure_network() {
    # Every network carries the digest, so no network is created before the
    # current configuration has one.
    assert_config_digest_ready || return 1

    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        configure_proxy_network || return 1
    else
        if ! observed_resource_present "network:$NETWORK_NAME"; then
            record_launch_resource_attempt "network:$NETWORK_NAME"
            podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$NETWORK_NAME" || return 1
        fi
        NETWORK_STATE[selected_network]="$NETWORK_NAME"
        NETWORK_SSH_SESSION_ENV=()
        NETWORK_STATE[proxy_url]=""
        NETWORK_STATE[no_proxy]=""
    fi
}

configure_proxy_network() {
    # Egress enforcement model: direct container egress is blocked by an
    # internal-only Podman network (no external route). Outbound HTTP(S) is
    # brokered exclusively through the tinyproxy sidecar, which enforces the
    # EGRESS_ALLOW domain allowlist. Enforcement is proxy-mediated
    # (protocol/domain filter), not per-packet or firewall-level.
    #
    # Rootless, zero-capability Podman intentionally avoids NET_ADMIN,
    # iptables/nftables, and TUN/TProxy interception. Hostname-aware
    # transparent filtering would require one of those mechanisms. The chosen
    # topology trades transparent filtering for a simpler, capability-free
    # model: tools must cooperate with proxy configuration (HTTP_PROXY /
    # HTTPS_PROXY env, curlrc, wgetrc) to reach allowed hosts.
    local internal_net external_net effective_egress_allow proxy_internal_ip proxy_internal_subnet

    effective_egress_allowlist effective_egress_allow || return 1
    NETWORK_STATE[filter_file]="$SSH_DIR/tinyproxy-filter"

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    ensure_internal_network "$internal_net" || return 1
    if ! observed_resource_present "network:$external_net"; then
        record_launch_resource_attempt "network:$external_net"
        podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$external_net" || return 1
    fi

    # Derive the proxy address from the network's actual subnet rather than
    # recomputing the hash candidate: an existing network may have been
    # created on a fallback subnet after a collision.
    proxy_internal_subnet=$(internal_network_subnet "$internal_net") || {
        echo "Error: could not determine subnet of internal network $internal_net" >&2
        return 1
    }
    [ -n "$proxy_internal_subnet" ] || die "could not determine subnet of internal network $internal_net"
    proxy_internal_ip=$(proxy_ip_for_subnet "$proxy_internal_subnet") || return 1

    NETWORK_STATE[proxy_conf_file]="$SSH_DIR/tinyproxy.conf"
    if [ "$OBSERVED_PROXY_STATE" = absent ]; then
        prepare_proxy_files || return 1
        render_tinyproxy_filter "${NETWORK_STATE[filter_file]}" "${effective_egress_allow[@]}" || return 1
        render_tinyproxy_conf "${NETWORK_STATE[proxy_conf_file]}" "$proxy_internal_subnet" || return 1
        record_launch_resource_attempt "container:$PROXY_NAME"

        start_proxy_container "$internal_net" "$external_net" "$proxy_internal_ip" "${#effective_egress_allow[@]}" || return 1
    elif [ "$OBSERVED_PROXY_STATE" != running ]; then
        podman start "$PROXY_NAME" || return 1
    fi

    NETWORK_STATE[selected_network]="$internal_net"
    NETWORK_STATE[internal_network]="$internal_net"
    NETWORK_STATE[proxy_url]="http://$proxy_internal_ip:8888"
    configure_proxy_env
}

initialize_convergence_state() {
    LAUNCH_CONVERGING=false
}

# Command-owned reset for a new launch; not part of read-only inspection.
reset_launch_attempts() {
    LAUNCH_ATTEMPTED_RESOURCES=()
    LAUNCH_ATTEMPTED_HOST_PATHS=()
    LAUNCH_RETAIN_HOME=false
    LAUNCH_SETUP_ACTIVE=false
    LAUNCH_SETUP_TEMP=''
    LAUNCH_SETUP_JOB=''
    LAUNCH_PREVIOUS_JOB=''
    LAUNCH_SETUP_PROVIDER=''
    LAUNCH_SETUP_INPUT_FD=''
    LAUNCH_SETUP_OUTPUT_FD=''
    LAUNCH_FORWARDING=false
}

# Record before attempting creation, excluding resources in the preflight
# snapshot. This updates bookkeeping only; it does not inspect or mutate Podman.
record_launch_resource_attempt() {
    observed_resource_present "$1" || LAUNCH_ATTEMPTED_RESOURCES+=("$1")
    return 0
}

# Callers establish that this path is disposable before recording it. Published
# material needed by surviving containers is retained even after failed launch.
record_launch_host_path_attempt() {
    LAUNCH_ATTEMPTED_HOST_PATHS+=("$1")
}

begin_launch_convergence() {
    LAUNCH_CONVERGING=true
}

fail_sandbox_readiness() {
    die "sandbox convergence failed after startup or synchronization began: $*. Sandbox state may have changed; cleanup and retained-resource reporting follow."
}

# EXIT callback armed before sandbox mutation. A successful launch needs no
# rollback; Bash retains the original failing exit status after this callback.
rollback_launch_on_exit() {
    [ "$1" -ne 0 ] || return 0
    local path job=${!:-} target
    [[ -z "$LAUNCH_SETUP_INPUT_FD" ]] || exec {LAUNCH_SETUP_INPUT_FD}<&-
    [[ -z "$LAUNCH_SETUP_OUTPUT_FD" ]] || exec {LAUNCH_SETUP_OUTPUT_FD}>&-
    if [[ -n "$LAUNCH_SETUP_JOB" && -n "$job" && "$job" != "$LAUNCH_PREVIOUS_JOB" ]]; then
        target=$job
        [[ "$LAUNCH_SETUP_JOB" != provider ]] || target=-$job
        # Bash can report the killed job between these two commands.
        {
            kill -KILL -- "$target" || true
            wait "$job" || true
        } 2>/dev/null
    fi
    for path in "$LAUNCH_SETUP_TEMP" "$LAUNCH_SETUP_PROVIDER"; do
        [[ -z "$path" ]] || rm -f -- "$path" || printf 'Error: could not remove temporary home setup material.\n' >&2
    done
    rollback_launch
}

rollback_launch() {
    local target kind name probe failed=false dependent=false state path index
    local dev_retained=false proxy_retained=false home_removed=false needed
    if [[ "$LAUNCH_FORWARDING" = true ]] && ! retire_forwarding; then
        failed=true
        printf 'Error: rollback could not retire host forwarding state.\n' >&2
    fi
    # 1. Remove only attempted containers, development before proxy. Never stop
    # a pre-existing survivor; a remaining development container needs its proxy.
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        for target in "${LAUNCH_ATTEMPTED_RESOURCES[@]}"; do
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
    # 2. Re-observe survivors. Failed inspection counts as a possible survivor,
    # so dependencies and authentication remain even for stopped containers.
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
    # 3. Remove attempted engine dependencies in reverse order when no survivor
    # needs them. A home belongs to the development container, not the proxy.
    for ((index=${#LAUNCH_ATTEMPTED_RESOURCES[@]}-1; index>=0; index--)); do
        target=${LAUNCH_ATTEMPTED_RESOURCES[index]}
        kind=${target%%:*}; name=${target#*:}
        [ "$kind" != container ] || continue
        if [ "$kind" = volume ] && [ "$LAUNCH_RETAIN_HOME" = true ]; then
            continue
        fi
        needed=$dependent
        [ "$kind" != volume ] || needed=$dev_retained
        if [ "$needed" = true ]; then
            printf "Retained dependency '%s'.\n" "$target" >&2
            continue
        fi
        probe=0
        jailbox_resource_exists "$kind" "$name" || probe=$?
        if [ "$probe" -eq 1 ] || { [ "$probe" -eq 0 ] && podman "$kind" rm "$name"; }; then
            [[ "$kind" != volume ]] || home_removed=true
        else
            failed=true
            printf "Error: cleanup retained '%s'.\n" "$target" >&2
        fi
    done
    # 4. Remove disposable host artifacts in reverse order, retaining the
    # credentials/configuration each survivor needs. Leave unrelated files alone.
    for ((index=${#LAUNCH_ATTEMPTED_HOST_PATHS[@]}-1; index>=0; index--)); do
        path=${LAUNCH_ATTEMPTED_HOST_PATHS[index]}
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
    if [[ "$LAUNCH_SETUP_ACTIVE" = true ]]; then
        if [[ "$home_removed" = false ]]; then
            printf '%s\n' "$(home_setup_recovery "$EPHEMERAL_HOME")" >&2
        elif [[ "$failed" = true ]]; then
            printf "Run 'jailbox stop' to remove surviving sandbox resources, then relaunch.\n" >&2
        else
            printf 'Fix the setup error, then relaunch to create a new home.\n' >&2
        fi
    else
        sandbox_stop_guidance >&2 || true
    fi
    [ "$failed" = false ]
}
