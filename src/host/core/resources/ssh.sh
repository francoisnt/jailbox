# SSH key/config generation and readiness waiting.

SSH_DIR=""
SSH_CONFIG=""
KNOWN_HOSTS=""
KEY_FILE=""
SSHD_RUNTIME_DIR=""
SSH_GENERATION_DIR=""

validation_ssh() {
    ssh -F "$SSH_CONFIG" -o ConnectTimeout=3 -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=2 "$CONTAINER_NAME" "$@"
}

validate_development_session() {
    local mode="$1" path arguments result proxy="" index payload status=0
    local -a paths=(/)
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do paths+=("$REMOTE_PATH/$path"); done
    if [[ "$mode" = full && -n "${EGRESS_ALLOW[*]-}" ]]; then proxy=${NETWORK_STATE[proxy_url]}; fi
    if [[ ! -f "$SCRIPT_DIR/container/checks/validate-session.sh" ]] ||
        ! payload=$(< "$SCRIPT_DIR/container/checks/validate-session.sh"); then
        refuse_local_validation 'could not read local validation payload; repair the jailbox installation before retrying'
        return 1
    fi
    printf -v arguments "%q " "$mode" "$REMOTE_PATH" "$proxy" "${paths[@]}"
    result=$(validation_ssh "bash -s -- $arguments" <<< "$payload" && printf '.') || status=$?
    if [[ "$status" != 0 ]]; then
        refuse_sandbox "SSH validation command failed (exit $status; transport or remote execution error)"
        return 1
    fi
    case "$result" in
        $'ok\n.') return 0 ;;
        $'authorized-keys\n.') refuse_sandbox 'authorized_keys is unavailable' ;;
        $'project-write\n.') refuse_local_validation 'managed user cannot write the project; correct host project ownership and permissions before retrying' ;;
        $'sockets\n.') refuse_sandbox 'runtime socket isolation could not be established' ;;
        $'hardening\n.') refuse_sandbox 'live process hardening could not be established' ;;
        $'proxy-env\n.') refuse_sandbox 'live SSH proxy settings differ from policy' ;;
        $'direct-route\n.') refuse_sandbox 'direct-route isolation could not be established' ;;
        *)
            for index in "${!paths[@]}"; do
                if [[ "$result" = "mount:$index"$'\n.' ]]; then
                    refuse_sandbox "read-only mount '${paths[index]}' could not be established"
                    return 1
                fi
            done
            refuse_sandbox 'invalid SSH validation response: expected one result; check shell startup files for unexpected output' ;;
    esac
    return 1
}

initialize_ssh_state() {
    [[ -n "$PROJECT_STATE_ROOT" && -n "$PROJECT_HASH" ]] || \
        die "internal error: SSH state requires initialized project state"
    SSH_DIR="$PROJECT_STATE_ROOT/projects/$PROJECT_HASH"
    SSH_GENERATION_DIR="$SSH_DIR/ssh-generation"
    SSH_CONFIG="$SSH_GENERATION_DIR/ssh_config"
    KNOWN_HOSTS="$SSH_GENERATION_DIR/known_hosts"
    KEY_FILE="$SSH_GENERATION_DIR/key"
    SSHD_RUNTIME_DIR="$SSH_GENERATION_DIR/server"
}

assert_ssh_state_initialized() {
    [[ -n "$SSH_DIR" && -n "$SSH_CONFIG" && -n "$KNOWN_HOSTS" &&
        -n "$KEY_FILE" && -n "$SSHD_RUNTIME_DIR" && -n "$SSH_GENERATION_DIR" ]] || \
        die "internal error: SSH state is not initialized"
}

ssh_state_error() {
    printf 'Error: SSH generation %s; run '\''jailbox stop'\'' then '\''jailbox up'\''.\n' "$*" >&2
    return 1
}

# An unsafe state path survives both stop and up, so naming the offending
# component and the manual fix is the only recovery a caller can act on.
ssh_state_path_error() {
    printf "Error: SSH state path '%s' %s; jailbox will not read or remove credentials through it.\n" "$1" "$2" >&2
    printf "Replace that path with a real directory, or point XDG_STATE_HOME at one, then run 'jailbox up'.\n" >&2
    return 1
}

# Never traverse a substituted directory while reading or removing secrets.
# Host ancestors may include /tmp; StrictModes parents inside the container
# are validated separately by the entrypoint.
validate_ssh_state_path() {
    local path="$SSH_DIR"
    if contains_control_character "$path"; then
        ssh_state_path_error "$SSH_DIR" "contains an ASCII control character"
        return 1
    fi
    [[ "$path" = /* ]] || { ssh_state_path_error "$SSH_DIR" 'is not absolute'; return 1; }
    while [ "$path" != / ]; do
        [ ! -L "$path" ] || { ssh_state_path_error "$path" 'is a symlink'; return 1; }
        if [[ -e "$path" && ! -d "$path" ]]; then
            ssh_state_path_error "$path" 'is not a directory'; return 1
        fi
        path=$(dirname "$path") || return 1
    done
}

ssh_generation_present() {
    local path
    # Include the pre-generation layout and interrupted preparation directories.
    for path in "$SSH_GENERATION_DIR" "$SSH_DIR"/.ssh-generation.* \
        "$SSH_DIR/key" "$SSH_DIR/key.pub" "$SSH_DIR/known_hosts" \
        "$SSH_DIR/known_hosts.old" "$SSH_DIR/ssh_config" "$SSH_DIR/sshd-runtime"; do
        if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    done
    return 1
}

require_ssh_generation_absent() {
    assert_ssh_state_initialized
    validate_ssh_state_path || return 1
    if ssh_generation_present; then
        ssh_state_error "is orphaned; refusing to overwrite existing material"
        return 1
    fi
}

remove_ssh_generation() {
    assert_ssh_state_initialized
    validate_ssh_state_path || return 1
    rm -rf -- "$SSH_GENERATION_DIR" "$SSH_DIR"/.ssh-generation.* \
        "$SSH_DIR/key" "$SSH_DIR/key.pub" "$SSH_DIR/known_hosts" \
        "$SSH_DIR/known_hosts.old" "$SSH_DIR/ssh_config" "$SSH_DIR/sshd-runtime"
}

# A private staging directory and one rename publish all credentials together.
# The subshell owns preparation cleanup even when a command exits via errexit.
create_ssh_generation() (
    set -e
    require_ssh_generation_absent || exit 1
    umask 077
    if [ -d "$SSH_DIR" ]; then
        validate_ssh_file "$SSH_DIR" 700 directory || {
            ssh_state_error 'has unsafe directory metadata'; exit 1;
        }
    else
        mkdir -p "$SSH_DIR" || exit 1
    fi
    stage=$(mktemp -d "$SSH_DIR/.ssh-generation.XXXXXXXX") || exit 1
    cleanup_ssh_stage() {
        if ! rm -rf -- "$stage"; then
            echo "Error: SSH preparation cleanup failed; run jailbox stop then jailbox up." >&2
            exit 1
        fi
    }
    trap cleanup_ssh_stage EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$stage/server" || exit 1
    ssh-keygen -t ed25519 -f "$stage/key" -N '' -C jailbox-client -q || exit 1
    ssh-keygen -t ed25519 -f "$stage/server/ssh_host_ed25519_key" -N '' -C jailbox-server -q || exit 1
    cp "$stage/key.pub" "$stage/server/authorized_keys" || exit 1
    chmod 600 "$stage/key" "$stage/server/ssh_host_ed25519_key" "$stage/server/authorized_keys" || exit 1
    chmod 644 "$stage/key.pub" "$stage/server/ssh_host_ed25519_key.pub" || exit 1
    printf '[localhost]:%s %s\n' "$LOCAL_PORT" "$(cat "$stage/server/ssh_host_ed25519_key.pub")" > "$stage/known_hosts" || exit 1
    write_ssh_host_block > "$stage/ssh_config" || exit 1
    validate_ssh_generation "$stage" || exit 1
    mv -- "$stage" "$SSH_GENERATION_DIR" || exit 1
)

ssh_file_metadata() {
    stat -c '%u:%a' "$1" 2>/dev/null || stat -f '%u:%Lp' "$1"
}

validate_ssh_file() {
    local path="$1" mode="$2" kind="$3" metadata
    [ ! -L "$path" ] || return 1
    if [ "$kind" = directory ]; then
        [ -d "$path" ] || return 1
    else
        [[ -f "$path" && -s "$path" ]] || return 1
    fi
    metadata=$(ssh_file_metadata "$path") || return 1
    [ "$metadata" = "$(id -u):$mode" ]
}

# The engine writes the container-ID receipt under the caller's umask, so its
# exact mode is not jailbox's to dictate. Require an owned, non-shared regular
# file instead: the 0700 generation directory already bounds who can reach it,
# and group or other write access is what would let another account forge the
# recorded identity.
validate_ssh_receipt() {
    local path="$SSH_GENERATION_DIR/container-id" metadata mode
    [ ! -L "$path" ] || return 1
    [[ -f "$path" && -s "$path" ]] || return 1
    metadata=$(ssh_file_metadata "$path") || return 1
    [ "${metadata%%:*}" = "$(id -u)" ] || return 1
    mode=${metadata#*:}
    # Validate before the arithmetic context so stat output cannot be evaluated.
    case "$mode" in ''|*[!0-7]*) return 1 ;; esac
    [ "$((8#$mode & 8#022))" -eq 0 ]
}

validate_ssh_pair() {
    local key="$1" derived published type bytes rest lines trailing
    derived=$(ssh-keygen -y -P '' -f "$key" 2>/dev/null) || return 1
    read -r type bytes rest < "$key.pub" || return 1
    published="$type $bytes"
    # Comments are not identity, but extra public-key records are invalid.
    lines=$(wc -l < "$key.pub") || return 1
    trailing=$(tail -n +2 "$key.pub") || return 1
    [ "$lines" -eq 1 ] || return 1
    [ -z "$trailing" ] || return 1
    [ "$derived" = "$published" ] || [ "${derived% *}" = "$published" ]
}

# Expected session configuration comes from validated policy and the live
# network. No file is sourced, repaired, or passed to ssh before comparison.
validate_ssh_generation() {
    local root="${1:-$SSH_GENERATION_DIR}" path mode public expected_config
    assert_ssh_state_initialized
    validate_ssh_state_path || return 1
    for path in "$SSH_DIR" "$root" "$root/server"; do
        validate_ssh_file "$path" 700 directory || { ssh_state_error 'has unsafe directory metadata'; return 1; }
    done
    for path in key key.pub known_hosts ssh_config server/authorized_keys \
        server/ssh_host_ed25519_key server/ssh_host_ed25519_key.pub; do
        mode=600
        case "$path" in *.pub) mode=644 ;; esac
        validate_ssh_file "$root/$path" "$mode" file || { ssh_state_error "has invalid $path metadata"; return 1; }
    done
    public=$(cat "$root/server/ssh_host_ed25519_key.pub") || { ssh_state_error 'could not read server public key'; return 1; }
    expected_config=$(write_ssh_host_block && printf '.') || { ssh_state_error 'could not render expected client configuration'; return 1; }
    if ! { validate_ssh_pair "$root/key" && validate_ssh_pair "$root/server/ssh_host_ed25519_key" &&
        cmp -s "$root/key.pub" "$root/server/authorized_keys" &&
        cmp -s "$root/known_hosts" <(printf '[localhost]:%s %s\n' "$LOCAL_PORT" "$public") &&
        cmp -s "$root/ssh_config" <(printf '%s' "${expected_config%.}"); }; then
        ssh_state_error 'has inconsistent keys, pin, or SSH configuration'
        return 1
    fi
}

# Podman's template compares paths in the engine, so tabs/newlines in a host
# path cannot be confused with inspection record separators.
ssh_inspect_quote() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//$'\b'/\\b}
    value=${value//$'\f'/\\f}
    value=${value//$'\v'/\\v}
    value=${value//$'\a'/\\a}
    printf '"%s"' "$value"
}

validate_ssh_container_mount() {
    local template result path
    template='{{range .Mounts}}{{if eq .Destination "/run/jailbox-sshd"}}{{if and (eq .Type "bind") (not .RW) (eq .Source '
    template+="$(ssh_inspect_quote "$SSHD_RUNTIME_DIR")"
    template+=')}}ok{{else}}invalid{{end}}{{end}}'
    template+='{{if ge (len .Destination) 18}}{{if eq (slice .Destination 0 18) "/run/jailbox-sshd/"}}overlay{{end}}{{end}}'
    # Reject mounts exposing the client files or any containing directory.
    for path in "$KEY_FILE" "$KNOWN_HOSTS" "$SSH_CONFIG"; do
        template+='{{if eq .Source '
        template+="$(ssh_inspect_quote "$path")"
        template+='}}exposed{{end}}'
    done
    path="$SSH_GENERATION_DIR"
    while :; do
        template+='{{if eq .Source '
        template+="$(ssh_inspect_quote "$path")"
        template+='}}exposed{{end}}'
        [ "$path" != / ] || break
        path=$(dirname "$path") || return 1
    done
    template+='{{end}}'
    result=$(podman container inspect "$CONTAINER_NAME" --format "$template") || {
        ssh_state_error 'mount inspection failed'; return 1;
    }
    [ "$result" = ok ] || { ssh_state_error 'has unsafe authentication mounts'; return 1; }
    validate_ssh_session_environment
}

# Compare inside the engine: arbitrary image environment values never enter
# a host-side line parser. Exactly one matching delivery variable is required.
validate_ssh_session_environment() {
    local template result expected
    expected=$(ssh_inspect_quote "JAILBOX_SSH_PROXY_URL=${NETWORK_STATE[proxy_url]}") || return 1
    template='{{range .Config.Env}}{{if ge (len .) 22}}{{if eq (slice . 0 22) "JAILBOX_SSH_PROXY_URL="}}{{if eq . '
    template+="$expected"
    template+='}}ok{{else}}invalid{{end}}{{end}}{{end}}{{end}}'
    result=$(podman container inspect "$CONTAINER_NAME" --format "$template") || {
        ssh_state_error 'session environment inspection failed'; return 1;
    }
    [ "$result" = ok ] || { ssh_state_error 'has inconsistent session environment'; return 1; }
}

validate_ssh_resume() {
    local recorded actual
    validate_ssh_generation || return 1
    validate_ssh_receipt || { ssh_state_error 'has invalid container identity metadata'; return 1; }
    recorded=$(cat "$SSH_GENERATION_DIR/container-id") || { ssh_state_error 'could not read container identity'; return 1; }
    [[ "$recorded" =~ ^[a-f0-9]{64}$ ]] || { ssh_state_error 'has invalid container identity'; return 1; }
    actual=$(podman container inspect "$CONTAINER_NAME" --format '{{.Id}}') || {
        ssh_state_error 'container identity inspection failed'; return 1;
    }
    [ "$recorded" = "$actual" ] || { ssh_state_error 'belongs to a different container'; return 1; }
    validate_ssh_container_mount
}

ssh_config_quote() {
    local value

    value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_ssh_host_block() {
    cat <<SSHEOF || return 1
Host $CONTAINER_NAME
    HostName localhost
    Port $LOCAL_PORT
    User $MANAGED_USER
    IdentityFile $(ssh_config_quote "$KEY_FILE")
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile $(ssh_config_quote "$KNOWN_HOSTS")
    GlobalKnownHostsFile /dev/null
    UpdateHostKeys no
    BatchMode yes
SSHEOF

    write_ssh_setenv '    '
}

write_ssh_setenv() {
    local indent="$1" env_pair setenv_line=""
    for env_pair in "${NETWORK_SSH_SESSION_ENV[@]}"; do
        setenv_line="${setenv_line:+$setenv_line }$env_pair"
    done
    if [ -n "$setenv_line" ]; then
        # Both OpenSSH client and server use only the first SetEnv directive.
        # Keep every variable on one line so none silently disappear.
        printf '%sSetEnv %s\n' "$indent" "$setenv_line"
    fi
}

print_ssh_config_instructions() {
    printf 'SSH config path: %s\nHost alias: %s\n' "$SSH_CONFIG" "$CONTAINER_NAME"
    if [ -e "$SSH_CONFIG" ] || [ -L "$SSH_CONFIG" ]; then
        printf 'Config path exists: yes\n'
    else
        printf 'Config path exists: no\n'
    fi
    printf 'Path existence does not establish safe attachment; use connection-info for validated metadata.\n'
    # Include expands glob patterns, tilde and tokens even inside quotes.
    if contains_control_character "$SSH_CONFIG" || [[ "$SSH_CONFIG" != /* || "$SSH_CONFIG" = *[\*\?\[\]%\$]* ]]; then
        printf 'This path cannot be represented safely in an SSH Include instruction.\n'
        return 0
    fi
    printf 'Manual ~/.ssh/config instruction:\n  Include %s\n' "$(ssh_config_quote "$SSH_CONFIG")"
}

wait_for_ssh() {
    local i SSH_READY
    echo "⏳ Waiting for sshd..."
    SSH_READY=false
    for ((i = 1; i <= 30; i++)); do
        if ssh -F "$SSH_CONFIG" -o ConnectTimeout=1 "$CONTAINER_NAME" true 2>/dev/null; then
            echo "✅ SSH is up (attempt $i)"
            SSH_READY=true
            break
        fi
        sleep 1
    done

    if [ "$SSH_READY" = false ]; then
        echo "Error: sshd did not become ready in time. Check container logs:" >&2
        echo "  podman logs $CONTAINER_NAME"
        podman logs "$CONTAINER_NAME" >&2 || true
        exit 1
    fi
}
