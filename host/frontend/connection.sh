# Public connection-info consumer. Nothing here inspects core state or SSH.
declare -A EDITOR_CONNECTION=()

connection_error() {
    printf 'Error: invalid connection-info: %s\n' "$*" >&2
    return 1
}

validate_connection_value() {
    local name=$1 value=$2 octet LC_ALL=C
    [[ ! "$value" =~ [$'\x01'-$'\x1f'$'\x7f'] ]] || return 1
    case "$name" in
        ssh_config|remote_path) [[ "$value" == /* && "$value" != / ]] ;;
        ssh_host) [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] ;;
        project_id) [[ "$value" =~ ^[0-9a-f]{12}$ ]] ;;
        proxy_url)
            [[ -n "$value" ]] || return 0
            [[ "$value" =~ ^http://([0-9]{1,3}\.){3}[0-9]{1,3}:8888$ ]] || return 1
            value=${value#http://}
            value=${value%:8888}
            local -a octets=()
            IFS=. read -ra octets <<< "$value"
            for octet in "${octets[@]}"; do
                ((10#$octet <= 255)) || return 1
            done
            ;;
        *) return 1 ;;
    esac
}

# Read NUL framing directly, publishing only a complete validated result.
parse_connection_records() {
    local file=$1 record name value index=0 LC_ALL=C
    local -a required=(ssh_config ssh_host remote_path project_id proxy_url)
    local -A seen=() parsed=()
    EDITOR_CONNECTION=()
    while :; do
        record=""
        if ! IFS= read -r -d '' record; then
            [[ -z "$record" ]] || { connection_error 'unterminated record'; return 1; }
            break
        fi
        [[ "$record" == *$'\t'* ]] || { connection_error 'missing TAB separator'; return 1; }
        name=${record%%$'\t'*}
        value=${record#*$'\t'}
        [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || { connection_error 'invalid field name'; return 1; }
        [[ ! -v seen[$name] ]] || { connection_error "duplicate field '$name'"; return 1; }
        seen["$name"]=1
        if ((index < ${#required[@]})); then
            [[ "$name" == "${required[index]}" ]] || { connection_error 'missing or reordered required field'; return 1; }
            validate_connection_value "$name" "$value" || { connection_error "invalid '$name' value"; return 1; }
            parsed["$name"]=$value
        fi
        index=$((index + 1))
    done < "$file" || return 1
    ((index >= ${#required[@]})) || { connection_error 'missing required field'; return 1; }
    for name in "${required[@]}"; do
        # shellcheck disable=SC2034 # Consumed by the editor client.
        EDITOR_CONNECTION["$name"]=${parsed[$name]}
    done
}
