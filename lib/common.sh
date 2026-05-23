# Common helpers and configuration loading.

usage() {
    local flag

    cat <<EOF_USAGE
Usage: $(basename "$0") [doctor|ssh-config|--clean|--help]

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
    local config_file

    config_file="$PROJECT_DIR/jailbox.conf"
    [ -f "$config_file" ] || return 0

    # jailbox.conf is deliberately data, not shell. Parse a tiny KEY=value
    # grammar explicitly so user config can never execute code through source,
    # command substitution, arithmetic expansion, or shell metacharacters.
    parse_config_file "$config_file" || return $?
    validate_config
}

trim() {
    local value

    value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

parse_config_file() {
    local config_file line trimmed line_no key value
    CONFIG_SEEN_KEYS=()

    config_file="$1"
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        trimmed=$(trim "$line")
        [ -z "$trimmed" ] && continue
        [[ "$trimmed" == \#* ]] && continue

        # Keep the grammar intentionally narrow: KEY=value, comments only as
        # full lines, optional matching quotes around values, no escapes. This
        # makes malformed config fail predictably and keeps parser behavior
        # easy to audit.
        if [[ "$trimmed" != *=* ]]; then
            die "invalid jailbox.conf line $line_no: expected KEY=value"
        fi

        key="${trimmed%%=*}"
        value=$(trim "${trimmed#*=}")

        if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            die "invalid jailbox.conf line $line_no: invalid key '${key}' (use KEY=value with no spaces around =)"
        fi
        if ! is_config_scalar_key "$key" && ! is_config_array_key "$key"; then
            die "invalid jailbox.conf line $line_no: unknown setting '$key'"
        fi
        if config_key_seen "$key"; then
            die "invalid jailbox.conf line $line_no: duplicate setting '$key'"
        fi
        CONFIG_SEEN_KEYS+=("$key")

        if is_config_array_key "$key"; then
            parse_config_array "$key" "$value" "$line_no" || return $?
        else
            parse_config_scalar "$key" "$value" "$line_no" || return $?
        fi
    done < "$config_file"
}

config_key_seen() {
    local key seen

    key="$1"
    for seen in "${CONFIG_SEEN_KEYS[@]}"; do
        [ "$seen" = "$key" ] && return 0
    done
    return 1
}

validate_config_value() {
    local value line_no

    value="$1"
    line_no="$2"

    # Values are atoms. Paths, image refs, stage names, and hostnames currently
    # do not need spaces; rejecting whitespace avoids quote/escape semantics.
    if [[ "$value" =~ [[:space:]] ]]; then
        die "invalid jailbox.conf line $line_no: values cannot contain whitespace"
    fi
    # Reject shell metacharacters even though values are not evaluated. This
    # keeps config visually unambiguous and prevents future call sites from
    # accidentally inheriting dangerous-looking strings.
    case "$value" in
        *'"'*|*'`'*|*'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*)
            die "invalid jailbox.conf line $line_no: unsupported character in value"
            ;;
    esac
}

unquote_config_value() {
    local value line_no first last

    value="$1"
    line_no="$2"
    first="${value:0:1}"
    last="${value: -1}"

    if [ "${#value}" -ge 2 ] && { { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; }; then
        printf '%s\n' "${value:1:${#value}-2}"
        return 0
    fi

    case "$value" in
        *'"'*|*"'"*)
            die "invalid jailbox.conf line $line_no: mismatched or embedded quote in value"
            ;;
    esac

    printf '%s\n' "$value"
}

parse_config_scalar() {
    local key value line_no

    key="$1"
    value="$2"
    line_no="$3"

    value=$(unquote_config_value "$value" "$line_no") || return $?
    validate_config_value "$value" "$line_no"
    if [[ "$value" == *,* ]]; then
        die "invalid jailbox.conf line $line_no: scalar setting '$key' cannot contain a comma"
    fi

    case "$key" in
        DEV_IMAGE) DEV_IMAGE="$value" ;;
        DEV_CONTAINERFILE) DEV_CONTAINERFILE="$value" ;;
        DEV_BUILD_CONTEXT) DEV_BUILD_CONTEXT="$value" ;;
        DEV_TARGET_STAGE) DEV_TARGET_STAGE="$value" ;;
    esac
}

parse_config_array() {
    local key raw_value line_no item items parts

    key="$1"
    raw_value="$2"
    line_no="$3"
    raw_value=$(unquote_config_value "$raw_value" "$line_no") || return $?
    items=()

    if [ -z "$raw_value" ]; then
        set_config_array "$key"
        return 0
    fi

    # Arrays are comma-separated data, not Bash arrays. That keeps the only
    # list syntax independent of shell parsing while remaining easy to edit.
    IFS=',' read -ra parts <<< "$raw_value"
    for item in "${parts[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || die "invalid jailbox.conf line $line_no: empty list item for '$key'"
        item=$(unquote_config_value "$item" "$line_no") || return $?
        validate_config_value "$item" "$line_no"
        items+=("$item")
    done

    set_config_array "$key" "${items[@]}"
}

set_config_array() {
    local key

    key="$1"
    shift

    case "$key" in
        EGRESS_ALLOW) EGRESS_ALLOW=("$@") ;;
    esac
}

validate_config() {
    validate_egress_allow
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
    SSH_DIR="$PROJECT_DIR/.jailbox"
    SSH_CONFIG="$SSH_DIR/ssh_config"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"
    KEY_FILE="$SSH_DIR/key"
    # Host-side backing store for sshd runtime state. It is bind-mounted to
    # /run/jailbox-sshd so the container path remains ephemeral daemon state,
    # while ownership still matches the non-root keep-id entrypoint.
    SSHD_RUNTIME_DIR="$SSH_DIR/sshd-runtime"
    JAILBOX_EDITOR_USER_DATA="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/editor-profiles/$PROJECT_HASH"
    JAILBOX_EDITOR_USER_SETTINGS="$JAILBOX_EDITOR_USER_DATA/User/settings.json"
}

initialize_runtime_ids() {
    # Stable port derived from the full project path (49152-65534).
    LOCAL_PORT=$(( 49152 + $(project_path_hash) % 16383 ))
    MY_UID=$(id -u)
}
