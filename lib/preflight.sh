# CLI parsing and host/tool validation.

parse_args() {
    case "${1:-}" in
        ""|--clean|--help) ;;
        *)
            usage >&2
            exit 2
            ;;
    esac

    if [[ "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi
}

host_preflight() {
    require_command podman

    if [[ "${1:-}" == "--clean" ]]; then
        return 0
    fi

    require_command ssh
    require_command ssh-keygen
    require_command cksum
    require_command realpath

    if command -v codium >/dev/null 2>&1; then
        EDITOR_BIN=$(command -v codium)
    elif command -v code >/dev/null 2>&1; then
        EDITOR_BIN=$(command -v code)
    else
        die "neither 'codium' nor 'code' was found in PATH; install VSCodium/VSCode CLI before launching jailbox"
    fi

    validate_ai_tools
}

validate_ai_tools() {
    local tool
    for tool in "${AI_TOOLS[@]}"; do
        [[ "$tool" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid AI tool name '$tool' (allowed: letters, numbers, dot, underscore, dash)"
        [ -f "$SCRIPT_DIR/install/${tool}.sh" ] || die "AI tool installer not found: $SCRIPT_DIR/install/${tool}.sh"
    done
}
