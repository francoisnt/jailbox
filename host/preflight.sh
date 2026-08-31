# CLI parsing and host/tool validation.

EDITOR_BIN=""

parse_args() {
    if [ "${1:-}" = "--config" ] || [ "${2:-}" = "--config" ]; then
        echo "Error: --config must appear before the command" >&2
        usage >&2
        exit 2
    fi
    if [ "$#" -gt 1 ]; then
        echo "Error: unexpected argument: $2" >&2
        usage >&2
        exit 2
    fi
    if ! is_cli_flag_allowed "${1:-}"; then
        usage >&2
        exit 2
    fi

    if [[ "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
}

# The derived port can collide with an unrelated listener; fail with a clear
# message instead of a confusing podman bind error or wait_for_ssh timeout.
# Launch requires both project containers to be absent, so no jailbox container
# of this project can be holding the port here.
check_local_port_available() {
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
    if [[ "${1:-}" == "ssh-config" || "${1:-}" == "doctor" ]]; then
        warn_low_inotify_watch_limit
        return 0
    fi

    require_command podman

    if [[ "${1:-}" == "--clean" || "${1:-}" == "stop" ]]; then
        return 0
    fi

    # cksum is only a fallback hash tool for jailbox_install_cache_bust, which
    # runs during the wrapper image build. Guard it after every early return so
    # the commands that never build an image do not inherit the requirement.
    require_command cksum
    require_command ssh
    require_command ssh-keygen
    require_command realpath
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
