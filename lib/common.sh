# Common helpers and configuration loading.

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [--clean|--help]

Launch this project inside a hardened jailbox container.

Options:
  --clean   Stop/remove jailbox containers, networks, and home volume
  --help    Show this help
EOF_USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

load_project_config() {
    if [ -f "$PROJECT_DIR/jailbox.conf" ]; then
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/jailbox.conf"
    fi
}

initialize_runtime_ids() {
    # Stable port derived from project name (49152–65534)
    LOCAL_PORT=$(( 49152 + $(printf '%s' "$PROJECT_NAME" | cksum | cut -d' ' -f1) % 16383 ))
    MY_UID=$(id -u)
}
