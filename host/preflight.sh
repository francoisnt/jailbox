# CLI parsing and host/tool validation.

EDITOR_BIN=""

validate_cli_implementation() {
    local command handler target
    public_api_validate_mapping 'command handlers' CLI_FLAGS_WITHOUT_VALUES CLI_COMMAND_HANDLERS
    public_api_validate_mapping 'option targets' CLI_FLAGS_WITH_VALUES CLI_OPTION_TARGETS
    for command in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        handler=${CLI_COMMAND_HANDLERS[$command]}
        [[ "$handler" =~ ^[a-z_][a-z0-9_]*$ ]] || public_api_error "invalid handler for '$command'"
        declare -F "$handler" >/dev/null || public_api_error "missing command handler '$handler' for '$command'"
    done
    for command in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        target=${CLI_OPTION_TARGETS[$command]}
        [[ "$target" =~ ^[A-Z][A-Z0-9_]*$ ]] || public_api_error "invalid option target for '$command'"
    done
}

run_version() {
    local version
    version=$(jailbox_version) || return 1
    printf 'jailbox %s\n' "$version"
}

parse_args() {
    local option arg
    for option in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        for arg in "$@"; do
            if [[ "$arg" = "$option" ]]; then
                echo "Error: $option must appear before the command" >&2
                usage >&2
                exit 2
            fi
        done
    done
    if [ "$#" -gt 1 ]; then
        echo "Error: unexpected argument: $2" >&2
        usage >&2
        exit 2
    fi
    if ! is_cli_flag_allowed "${1:-}"; then
        usage >&2
        exit 2
    fi
}

# The derived port can collide with an unrelated listener; fail with a clear
# message instead of a confusing podman bind error or wait_for_ssh timeout.
check_local_port_available() {
    # Only the caller that has validated the running container, its published
    # endpoint, and pinned SSH authentication can exempt its own listener.
    [ "${1:-}" != running ] || return 0
    if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then
        die "local port $LOCAL_PORT is already in use by another process. jailbox derives this port from the project path; stop the conflicting listener and relaunch."
    fi
}

warn_low_inotify_watch_limit() {
    local limit_file limit recommended

    recommended=524288
    limit_file="${JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE:-/proc/sys/fs/inotify/max_user_watches}"
    [ -r "$limit_file" ] || return 0

    limit=$(cat "$limit_file" 2>/dev/null || true)
    [[ "$limit" =~ ^[0-9]+$ ]] || return 0
    [ "$limit" -ge "$recommended" ] && return 0

    echo "⚠️  fs.inotify.max_user_watches is $limit; VSCodium/VS Code Remote SSH may be unable to watch workspace file changes." >&2
    echo "   Fix on the Linux host: echo 'fs.inotify.max_user_watches=$recommended' | sudo tee /etc/sysctl.d/60-jailbox-inotify.conf && sudo sysctl --system" >&2
}

host_preflight() {
    require_command podman

    # Only launch handlers use this preflight. Other commands check their own
    # dependencies, so they never inherit image-build or editor requirements.
    require_command cksum
    require_command ssh
    require_command ssh-keygen
    require_command realpath

    # Command mode launches the same sandbox without discovering, validating,
    # configuring, or warning about a host editor.
    if [[ "${1:-}" = up ]]; then
        return 0
    fi

    warn_low_inotify_watch_limit

    local requested_editor

    requested_editor="${JAILBOX_EDITOR:-$EDITOR}"
    case "$requested_editor" in
        "")
            ;;
        codium|code)
            EDITOR_BIN=$(command -v "$requested_editor" 2>/dev/null || true)
            [ -n "$EDITOR_BIN" ] || die "EDITOR=$requested_editor was requested, but '$requested_editor' was not found in PATH"
            return 0
            ;;
        *)
            die "invalid EDITOR='$requested_editor' (expected 'codium' or 'code')"
            ;;
    esac

    if command -v codium >/dev/null 2>&1; then
        EDITOR_BIN=$(command -v codium)
    elif command -v code >/dev/null 2>&1; then
        EDITOR_BIN=$(command -v code)
    else
        die "neither 'codium' nor 'code' was found in PATH; install VSCodium/VSCode CLI before launching jailbox"
    fi

}
