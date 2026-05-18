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
    local config_file line line_no
    local blank_re scalar_re quoted_scalar_re array_re
    local scalar_keys array_keys value_atom array_item quoted_array_item

    config_file="$PROJECT_DIR/jailbox.conf"
    [ -f "$config_file" ] || return 0

    scalar_keys='DEV_IMAGE|DEV_CONTAINERFILE|DEV_BUILD_CONTEXT|DEV_TARGET_STAGE|EXTRA_PACKAGES|REMOTE_PATH|CLAUDE_INSTALL_SHA256|AIDER_VERSION'
    array_keys='AI_TOOLS|EGRESS_ALLOW'
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
}

validate_egress_allow() {
    local host

    for host in "${EGRESS_ALLOW[@]}"; do
        [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] || \
            die "invalid EGRESS_ALLOW host '$host' (use hostnames like github.com, without URLs, wildcards, or regex)"
    done
}

initialize_runtime_ids() {
    # Stable port derived from project name (49152–65534)
    LOCAL_PORT=$(( 49152 + $(printf '%s' "$PROJECT_NAME" | cksum | cut -d' ' -f1) % 16383 ))
    MY_UID=$(id -u)
}
