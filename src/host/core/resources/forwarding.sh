# Project-bound host command forwarding. Core owns the snapshot and connection.

FORWARD_POLICY_FRAME=''
FORWARD_POLICY_DIGEST=''
FORWARD_POLICY_DESCRIPTION=''
FORWARD_PYTHON=''

select_forwarding_python() {
    local candidate resolved
    candidate=$(type -P python3) || die 'host forwarding requires python3'
    [[ "$candidate" = /* ]] || die 'host forwarding requires python3 on an absolute PATH entry'
    require_host_realpath || return 1
    resolved=$(realpath -- "$candidate") || return 1
    if [[ "$candidate" = "$PROJECT_DIR/"* || "$resolved" = "$PROJECT_DIR/"* ]]; then
        die 'host forwarding requires python3 outside the project tree'
    fi
    FORWARD_PYTHON=$candidate
}

forwarding_tool() {
    [[ -n "$FORWARD_PYTHON" ]] || select_forwarding_python || return 1
    "$FORWARD_PYTHON" -I -B "$SCRIPT_DIR/host/core/resources/forwarding/main.py" "$@"
}

resolve_forwarding_policy_path() {
    local relative hidden
    relative=$(check_configured_project_path "$HOST_COMMAND_POLICY" HOST_COMMAND_POLICY) || return 1
    [[ -f "$PROJECT_DIR/$relative" && -r "$PROJECT_DIR/$relative" ]] ||
        die "HOST_COMMAND_POLICY must be a readable regular file: $relative"
    for hidden in "$@"; do
        if project_paths_overlap "$relative" "$hidden"; then
            die "HOST_COMMAND_POLICY path '$relative' conflicts with HIDDEN_PATHS path '$hidden'"
        fi
    done
    printf '%s\n' "$relative"
}

capture_forwarding_policy() {
    FORWARD_POLICY_FRAME=''
    FORWARD_POLICY_DIGEST=''
    [[ -n "${HOST_COMMAND_POLICY:-}" ]] || return 0
    select_forwarding_python || return 1
    resolve_forwarding_policy_path "${HIDDEN_PATHS[@]}" >/dev/null || return 1
    FORWARD_POLICY_FRAME=$(forwarding_tool capture "$PROJECT_DIR" "$HOST_COMMAND_POLICY") || return 1
    FORWARD_POLICY_DIGEST=$(forwarding_tool hash <<< "$FORWARD_POLICY_FRAME") || return 1
    is_config_digest_value "$FORWARD_POLICY_DIGEST" || return 1
}

describe_forwarding_policy() {
    [[ -n "${HOST_COMMAND_POLICY:-}" ]] || return 0
    FORWARD_POLICY_DESCRIPTION=$(forwarding_tool describe "$PROJECT_DIR" <<< "$FORWARD_POLICY_FRAME") || return 1
}

# 0 present, 1 absent, 2 unobservable. Test directory access before an
# existence check can mistake an inaccessible state path for absence.
forwarding_state_present() {
    local dir="$SSH_DIR"
    validate_ssh_state_path || return 2
    while [[ "$dir" != / ]]; do
        if [[ -d "$dir" && ( ! -r "$dir" || ! -x "$dir" ) ]]; then
            printf 'Error: could not inspect host forwarding state.\n' >&2
            return 2
        fi
        dir=${dir%/*}
        dir=${dir:-/}
    done
    [[ -e "$SSH_DIR/forwarding" || -L "$SSH_DIR/forwarding" ]]
}

retire_forwarding() {
    local probe=0
    forwarding_state_present || probe=$?
    case "$probe" in
        0) forwarding_tool retire "$SSH_DIR/forwarding" ;;
        1) return 0 ;;
        *) return 1 ;;
    esac
}

publish_forwarding_policy() {
    assert_project_path_policy_ready || return 1
    forwarding_tool publish "$PROJECT_DIR" "$SSH_DIR/forwarding" "$SSHD_RUNTIME_DIR" "$FORWARD_POLICY_DIGEST" \
        "${EFFECTIVE_HIDDEN_PATHS[@]}" \
        <<< "$FORWARD_POLICY_FRAME"$'\n'"$FORWARD_POLICY_DESCRIPTION"
}

validate_forwarding_home_storage() {
    local home
    home=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}') || return 1
    forwarding_tool storage "$home" <<< "$FORWARD_POLICY_DESCRIPTION"
}

forwarding_container_identity() {
    local generation
    validate_ssh_receipt || return 1
    generation=$(< "$SSH_GENERATION_DIR/container-id") || return 1
    [[ "$generation" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$generation"
}

check_forwarding_lookup() {
    local names command checks
    names=$(forwarding_tool names "$SSH_DIR/forwarding") || return 1
    [[ -n "$names" ]] || return 0
    # Names are validated by the policy parser. Quote them again when
    # constructing the remote Bash command.
    local -a arguments
    read -r -a arguments <<< "$names"
    # shellcheck disable=SC2016 # The checks run in the sandbox.
    printf -v checks '%s' '
        for name do
            [[ $(command -v -- "$name") == "/run/jailbox-sshd/host-commands/$name" &&
                -x "/run/jailbox-sshd/host-commands/$name" ]] || {
                printf "Error: jailbox forwarding shim is unavailable or shadowed for %s\n" "$name" >&2
                exit 1
            }
        done'
    printf -v command '%q ' /bin/bash -c "$checks" bash "${arguments[@]}"
    forwarding_ssh "$command" </dev/null || return 1
    printf -v command '%q ' /bin/bash -lc "$checks" bash "${arguments[@]}"
    forwarding_ssh "$command" </dev/null || return 1
    podman exec "$CONTAINER_NAME" /bin/bash -c "$checks" bash "${arguments[@]}" || return 1
}

forwarding_ssh() {
    ssh -F "$SSH_CONFIG" -T -o ConnectTimeout=3 -o ServerAliveInterval=2 \
        -o ServerAliveCountMax=2 "$CONTAINER_NAME" "$@"
}

probe_forwarding() {
    local generation=$1 response challenge expected result
    response=$(forwarding_tool check "$SSH_DIR/forwarding" "$generation") || return 1
    read -r challenge expected <<< "$response"
    is_config_digest_value "$challenge" && is_config_digest_value "$expected" || return 1
    # A fresh challenge proves the remote socket reaches this host service.
    result=$(forwarding_ssh "/usr/local/bin/jailbox-forward-client --probe $challenge" </dev/null) || return 1
    [[ "$result" = "$expected" ]]
}

start_forwarding() {
    local generation mounts attempt
    generation=$(forwarding_container_identity) || return 1
    mounts=$(podman container inspect "$CONTAINER_NAME" --format '{{json .Mounts}}') || return 1
    check_forwarding_lookup || return 1
    forwarding_tool start "$SSH_DIR/forwarding" "$generation" "$SSH_CONFIG" "$CONTAINER_NAME" <<< "$mounts" || return 1
    for ((attempt = 0; attempt < 25; attempt++)); do
        if probe_forwarding "$generation" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    [[ ! -f "$SSH_DIR/forwarding/ssh.log" ]] || cat -- "$SSH_DIR/forwarding/ssh.log" >&2
    fail_sandbox_readiness 'host forwarding did not become ready'
}

require_forwarding_health() {
    local generation
    generation=$(forwarding_container_identity) || return 1
    probe_forwarding "$generation" || return 1
    check_forwarding_lookup
}

validate_forwarding_reuse() {
    local probe=0
    forwarding_state_present || probe=$?
    [[ "$probe" -ne 2 ]] || return 1
    if [[ "$OBSERVED_DEV_STATE" = absent || -z "${HOST_COMMAND_POLICY:-}" ]]; then
        [[ "$probe" = 1 ]] || refuse_sandbox 'orphaned host forwarding state'
        return
    fi
    if [[ "$OBSERVED_DEV_STATE" != running || "$probe" != 0 ]] || ! require_forwarding_health; then
        refuse_sandbox 'host forwarding is unavailable for the current container generation'
    fi
}
