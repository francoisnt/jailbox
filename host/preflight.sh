# CLI parsing and host/tool validation.

parse_args() {
    if ! is_cli_flag_allowed "${1:-}"; then
        usage >&2
        exit 2
    fi

    if [[ "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
}

host_preflight() {
    require_command cksum

    if [[ "${1:-}" == "ssh-config" || "${1:-}" == "doctor" ]]; then
        return 0
    fi

    require_command podman

    if [[ "${1:-}" == "--clean" ]]; then
        return 0
    fi

    require_command ssh
    require_command ssh-keygen
    require_command realpath

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
