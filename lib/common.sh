# Common helpers and configuration loading.

usage() {
    local flag

    cat <<EOF_USAGE
Usage: $(basename "$0") [ssh-config|--clean|--help]

Launch this project inside a hardened jailbox container.

Options:
EOF_USAGE

    for flag in "${CLI_FLAGS[@]}"; do
        printf '  %-8s %s\n' "$flag" "$(cli_flag_help "$flag")"
    done
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

load_project_config() {
    local config_file line line_no
    local blank_re scalar_re quoted_scalar_re array_re
    local scalar_keys array_keys value_atom array_item quoted_array_item

    config_file="$PROJECT_DIR/jailbox.conf"
    [ -f "$config_file" ] || return 0

    scalar_keys=$(config_scalar_key_regex)
    array_keys=$(config_array_key_regex)
    value_atom='[A-Za-z0-9_./:,@%+=~-]+'
    quoted_array_item='"[A-Za-z0-9_./:,@%+=~-]+"'
    array_item="(${value_atom}|${quoted_array_item})"

    blank_re='^[[:space:]]*($|#)'
    scalar_re="^[[:space:]]*(${scalar_keys})=(${value_atom})?[[:space:]]*$"
    quoted_scalar_re="^[[:space:]]*(${scalar_keys})=\"[A-Za-z0-9_./:,@%+=~ -]*\"[[:space:]]*$"
    array_re="^[[:space:]]*(${array_keys})=\\([[:space:]]*(${array_item}([[:space:]]+${array_item})*)?[[:space:]]*\\)[[:space:]]*$"

    # Keep jailbox.conf as Bash assignment syntax, but only source it after
    # every non-comment line matches a small allowlist. This preserves simple
    # array config without executing arbitrary shell.
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [[ "$line" =~ $blank_re ]] && continue
        [[ "$line" =~ $scalar_re ]] && continue
        [[ "$line" =~ $quoted_scalar_re ]] && continue
        [[ "$line" =~ $array_re ]] && continue
        die "invalid jailbox.conf line $line_no: only simple allowlisted assignments are supported"
    done < "$config_file"

    # shellcheck source=/dev/null
    source "$config_file"
    validate_egress_allow

    # If REMOTE_PATH was not explicitly set in jailbox.conf it still holds the
    # default value which was hardcoded to devuser.  Re-derive it now that
    # DEV_USER is final so both always agree.
    if [ "$REMOTE_PATH" = "/home/devuser/project" ]; then
        REMOTE_PATH="/home/$DEV_USER/project"
    fi
}

validate_egress_allow() {
    local host

    for host in "${EGRESS_ALLOW[@]}"; do
        [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || \
            die "invalid EGRESS_ALLOW host '$host' (use hostnames like github.com, without URLs, wildcards, or regex)"
    done
}

project_path_hash() {
    printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1
}

initialize_project_names() {
    PROJECT_HASH=$(project_path_hash)
    PROJECT_RESOURCE_PREFIX="jailbox-$PROJECT_HASH"
    PROJECT_DEV_IMAGE="${PROJECT_RESOURCE_PREFIX}-dev"
    JAILBOX_IMAGE="${PROJECT_RESOURCE_PREFIX}-image"
    CONTAINER_NAME="${PROJECT_RESOURCE_PREFIX}"
    PROXY_NAME="${PROJECT_RESOURCE_PREFIX}-proxy"
    PROXY_IMAGE="${PROJECT_RESOURCE_PREFIX}-proxy"
    VOLUME_NAME="${PROJECT_RESOURCE_PREFIX}-home"
    NETWORK_NAME="${PROJECT_RESOURCE_PREFIX}-net"
    SSH_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/$PROJECT_HASH"
    SSH_CONFIG="$SSH_DIR/ssh_config"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"
    KEY_FILE="$SSH_DIR/key"
}

initialize_runtime_ids() {
    # Stable port derived from the full project path (49152-65534).
    LOCAL_PORT=$(( 49152 + $(project_path_hash) % 16383 ))
    MY_UID=$(id -u)
}
