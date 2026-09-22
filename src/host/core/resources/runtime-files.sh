# resources — runtime files

generate_minimal_gitconfig() (
    # This scope owns only its staging file; launch rollback owns published files.
    local gitconfig_file name email tmp_file="" parent
    cleanup_gitconfig() {
        local status=$?
        if [ -n "$tmp_file" ]; then
            rm -f -- "$tmp_file" || { echo "Error: could not clean temporary Git identity: $tmp_file" >&2; [ "$status" -ne 0 ] || status=1; }
        fi
        exit "$status"
    }
    trap cleanup_gitconfig EXIT
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

configure_runtime_mounts() {
    local path
    validate_ssh_state_path || return 1
    if [ ! -d "$SSH_DIR" ]; then
        record_launch_host_path_attempt "$SSH_DIR"
        # New parent directories are private too; leave existing parents unchanged.
        (umask 077; mkdir -p -- "$SSH_DIR") || return 1
    fi
    validate_ssh_file "$SSH_DIR" 700 directory || refuse_sandbox 'unsafe runtime directory metadata'
    # Existing unrelated runtime files are preserved, including gitconfig.
    GITCONFIG_MOUNT=()
    path="$SSH_DIR/gitconfig"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        record_launch_host_path_attempt "$path"
        generate_minimal_gitconfig "$path" || return 1
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        [[ -f "$path" && ! -L "$path" ]] || die 'unsafe runtime gitconfig'
        GITCONFIG_MOUNT=(-v "$path:/home/$MANAGED_USER/.gitconfig:ro")
    fi
    ROOTFS_FLAG=(--read-only)
    record_launch_host_path_attempt "$SSH_GENERATION_DIR"
}

# Validate generated-file paths without repair or publication.
validate_runtime_files() {
    local path
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
}
