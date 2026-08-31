# Common helpers and configuration loading.

# shellcheck source=host/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-id.sh"

declare -A CONFIG_SEEN_KEYS=()

CONFIG_PATH_ARG=""
CONFIG_FILE=""
DEFAULT_CONFIG_INPUT=""
SELECTED_CONFIG_INPUT=""
DEFAULT_CONFIG_PRESENT=0

PROJECT_HASH=""
PROJECT_RESOURCE_PREFIX=""
PROJECT_STATE_ROOT=""
CONTAINER_NAME=""
PROXY_NAME=""
PROXY_IMAGE=""
VOLUME_NAME=""
NETWORK_NAME=""
LOCAL_PORT=""
MY_UID=""
MANAGED_USER="jailbox"
REMOTE_PATH="/home/jailbox/project"

usage() {
    local flag

    cat <<EOF_USAGE
Usage: $(basename "$0") [--config PATH] [init|stop|doctor|ssh-config|--clean|--uninstall|--help]

Launch this project inside a hardened jailbox container.

Options:
EOF_USAGE

    for flag in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        printf '  %-14s %s\n' "$flag PATH" "$(cli_flag_help "$flag")"
    done
    for flag in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        printf '  %-14s %s\n' "$flag" "$(cli_flag_help "$flag")"
    done
}

command_requires_config() {
    [ -z "${1:-}" ]
}

init_project_config() {
    local destination tmp_file

    destination="$PROJECT_DIR/jailbox.conf"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        die "jailbox.conf already exists; refusing to overwrite it"
    fi

    tmp_file=$(mktemp "$PROJECT_DIR/.jailbox.conf.tmp.XXXXXX") || \
        die "could not create temporary project configuration"
    if ! printf '%s\n' \
        '# Additional project paths mounted read-only inside the sandbox.' \
        'READONLY_PATHS=' > "$tmp_file"; then
        rm -f -- "$tmp_file"
        die "could not write temporary project configuration"
    fi

    if ln -- "$tmp_file" "$destination" 2>/dev/null; then
        rm -f -- "$tmp_file"
        echo "Created $destination"
        return 0
    fi

    rm -f -- "$tmp_file"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        die "jailbox.conf already exists; refusing to overwrite it"
    fi
    die "could not publish $destination"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Print the canonical project-relative spelling of an existing path. Return
# non-zero when either side cannot be canonicalized or the path is outside the
# project. Callers decide whether absence/outside containment is an error or
# simply means the path needs no project mount.
canonical_project_relative_path() {
    local candidate project_abs candidate_abs

    candidate="$1"
    project_abs=$(realpath -- "$PROJECT_DIR" 2>/dev/null) || return 1
    candidate_abs=$(realpath -- "$candidate" 2>/dev/null) || return 1
    [ -e "$candidate_abs" ] || return 1
    [[ "$candidate_abs" == "$project_abs/"* ]] || return 1
    printf '%s\n' "${candidate_abs#"$project_abs"/}"
}

validate_project_mount_path_lexical() {
    local path

    path="$1"
    case "$path" in
        "") return 1 ;;
        /*) return 1 ;;
        *//* ) return 1 ;;
        .|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
        *:*) return 1 ;;
        */) return 1 ;;
    esac
}

check_project_path_no_symlinks() {
    local relative current component
    local -a components

    relative="$1"
    current=$(realpath -- "$PROJECT_DIR" 2>/dev/null) || return 1
    IFS='/' read -ra components <<< "$relative"
    for component in "${components[@]}"; do
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done
}

project_path_type() {
    local path

    path="$1"
    if [ -f "$path" ]; then
        printf 'file\n'
    elif [ -d "$path" ]; then
        printf 'directory\n'
    else
        printf 'special\n'
    fi
}

check_project_mount_path() {
    local path candidate relative type

    path="$1"
    validate_project_mount_path_lexical "$path" || return 1
    candidate="$(realpath -- "$PROJECT_DIR" 2>/dev/null)/$path"
    check_project_path_no_symlinks "$path" || return 3
    [ -e "$candidate" ] || return 2
    relative=$(canonical_project_relative_path "$candidate") || return 4
    type=$(project_path_type "$candidate")
    [ "$type" != special ] || return 5
    printf '%s\n' "$relative"
}

check_readonly_path() {
    local path result status

    path="$1"
    status=0
    result=$(check_project_mount_path "$path") || status=$?
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$result"
        return 0
    fi
    case "$status" in
        1) die "invalid READONLY_PATHS path '$path' (use a non-empty project-relative path without dot segments, colons, or a trailing slash)" ;;
        2) die "READONLY_PATHS path does not exist: $path" ;;
        3) die "READONLY_PATHS path contains a symlink: $path" ;;
        4) die "READONLY_PATHS path resolves outside the project: $path" ;;
        5) die "READONLY_PATHS path is not a regular file or directory: $path" ;;
    esac
}

check_path_no_symlinks() {
    local path current component
    local -a components

    path="$1"
    case "$path" in
        /*) current=/ ;;
        *) current="$PWD" ;;
    esac
    IFS='/' read -ra components <<< "$path"
    for component in "${components[@]}"; do
        [ -z "$component" ] && continue
        [ "$component" = . ] && continue
        if [ "$component" = .. ]; then
            current=$(dirname "$current")
            continue
        fi
        current="${current%/}/$component"
        [ ! -L "$current" ] || return 1
    done
}

classify_trusted_file() {
    local path description canonical relative

    path="$1"
    description="$2"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -f "$path" ] || die "$description path is not a regular file: $path"
    [ -r "$path" ] || die "$description path is not readable: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    relative=""
    relative=$(canonical_project_relative_path "$canonical" 2>/dev/null || true)
    printf '%s\t%s\n' "$canonical" "$relative"
}

classify_trusted_directory() {
    local path description canonical

    path="$1"
    description="$2"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -d "$path" ] || die "$description path is not a directory: $path"
    [ -r "$path" ] && [ -x "$path" ] || die "$description path is not accessible: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    printf '%s\n' "$canonical"
}

prepare_config_selection() {
    local command selected classified status

    command="${1:-}"

    require_command realpath
    DEFAULT_CONFIG_INPUT="$PROJECT_DIR/jailbox.conf"
    DEFAULT_CONFIG_PRESENT=0
    SELECTED_CONFIG_INPUT=""
    if [ -e "$DEFAULT_CONFIG_INPUT" ] || [ -L "$DEFAULT_CONFIG_INPUT" ]; then
        status=0
        classified=$(classify_trusted_file "$DEFAULT_CONFIG_INPUT" "default config") || status=$?
        [ "$status" -eq 0 ] || return "$status"
        DEFAULT_CONFIG_PRESENT=1
    elif command_requires_config "$command"; then
        die "Project is not initialized: jailbox.conf is required even with --config so the sandbox cannot create policy for a later bare launch. Run 'jailbox init'."
    fi

    if [ -n "$CONFIG_PATH_ARG" ]; then
        case "$CONFIG_PATH_ARG" in
            /*) selected="$CONFIG_PATH_ARG" ;;
            *) selected="$PWD/$CONFIG_PATH_ARG" ;;
        esac
    else
        selected=""
        [ -e "$DEFAULT_CONFIG_INPUT" ] && selected="$DEFAULT_CONFIG_INPUT"
    fi

    CONFIG_FILE=""
    [ -n "$selected" ] || return 0

    SELECTED_CONFIG_INPUT="$selected"
    status=0
    classified=$(classify_trusted_file "$SELECTED_CONFIG_INPUT" "config") || status=$?
    [ "$status" -eq 0 ] || return "$status"
    CONFIG_FILE="${classified%%$'\t'*}"
}

load_project_config() {
    local config_file

    config_file="$CONFIG_FILE"
    [ -n "$config_file" ] || return 0

    # jailbox.conf is deliberately data, not shell. Parse a tiny KEY=value
    # grammar explicitly so user config can never execute code through source,
    # command substitution, arithmetic expansion, or shell metacharacters.
    parse_config_file "$config_file" || return $?
    validate_config
}

config_die() {
    local line_no message display_path

    line_no="$1"
    message="$2"
    display_path="${CONFIG_PATH_ARG:-${CONFIG_FILE:-$PROJECT_DIR/jailbox.conf}}"
    die "invalid config '$display_path' line $line_no: $message"
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
            config_die "$line_no" "expected KEY=value"
        fi

        key="${trimmed%%=*}"
        value=$(trim "${trimmed#*=}")

        if ! [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            config_die "$line_no" "invalid key '${key}' (use KEY=value with no spaces around =)"
        fi
        if ! is_config_scalar_key "$key" && ! is_config_array_key "$key"; then
            config_die "$line_no" "unknown setting '$key'"
        fi
        if config_key_seen "$key"; then
            config_die "$line_no" "duplicate setting '$key'"
        fi
        CONFIG_SEEN_KEYS["$key"]=1

        if is_config_array_key "$key"; then
            parse_config_array "$key" "$value" "$line_no" || return $?
        else
            parse_config_scalar "$key" "$value" "$line_no" || return $?
        fi
    done < "$config_file"
}

config_key_seen() {
    local key

    key="$1"
    [[ -v CONFIG_SEEN_KEYS[$key] ]]
}

validate_config_value() {
    local value line_no

    value="$1"
    line_no="$2"

    # Values are atoms. Paths, image refs, stage names, and hostnames currently
    # do not need spaces; rejecting whitespace avoids quote/escape semantics.
    if [[ "$value" =~ [[:space:]] ]]; then
        config_die "$line_no" "values cannot contain whitespace"
    fi
    # Reject shell metacharacters even though values are not evaluated. This
    # keeps config visually unambiguous and prevents future call sites from
    # accidentally inheriting dangerous-looking strings.
    case "$value" in
        *'"'*|*'`'*|*'$'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*)
            config_die "$line_no" "unsupported character in value"
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
            config_die "$line_no" "mismatched or embedded quote in value"
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
        config_die "$line_no" "scalar setting '$key' cannot contain a comma"
    fi

    case "$key" in
        DEV_IMAGE) DEV_IMAGE="$value" ;;
        DEV_CONTAINERFILE) DEV_CONTAINERFILE="$value" ;;
        DEV_BUILD_CONTEXT) DEV_BUILD_CONTEXT="$value" ;;
        DEV_TARGET_STAGE) DEV_TARGET_STAGE="$value" ;;
        EDITOR) EDITOR="$value" ;;
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
        [ -n "$item" ] || config_die "$line_no" "empty list item for '$key'"
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
        READONLY_PATHS) READONLY_PATHS=("$@") ;;
    esac
}

validate_config() {
    validate_editor_config
    validate_egress_allow
    validate_readonly_paths_lexical
}

validate_editor_config() {
    case "$EDITOR" in
        ""|codium|code)
            ;;
        *)
            die "invalid EDITOR '$EDITOR' (use 'codium' or 'code')"
            ;;
    esac
}

validate_egress_allow() {
    local host

    for host in "${EGRESS_ALLOW[@]}"; do
        # Single-label names such as localhost or proxy are intentionally
        # rejected: this allowlist is for internet-routable domain names only.
        [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || \
            die "invalid EGRESS_ALLOW host '$host' (use hostnames like github.com, without URLs, wildcards, or regex)"
    done
}

validate_readonly_paths_lexical() {
    local path seen
    declare -A seen=()

    for path in "${READONLY_PATHS[@]}"; do
        validate_project_mount_path_lexical "$path" || \
            die "invalid READONLY_PATHS path '$path' (use a non-empty project-relative path without dot segments, colons, or a trailing slash)"
        [[ ! -v seen[$path] ]] || die "duplicate READONLY_PATHS path: $path"
        seen["$path"]=1
    done
}

project_path_hash() {
    jailbox_project_hash_for_path "$PROJECT_DIR"
}

initialize_project_names() {
    PROJECT_HASH=$(project_path_hash)
    # Podman resources carry the project name for readability; the hash of
    # the full path remains the identity. State directories below stay keyed
    # on the hash alone.
    PROJECT_RESOURCE_PREFIX=$(jailbox_resource_prefix_for_path "$PROJECT_DIR")
    PROJECT_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox"
    CONTAINER_NAME="${PROJECT_RESOURCE_PREFIX}"
    PROXY_NAME="${PROJECT_RESOURCE_PREFIX}-proxy"
    PROXY_IMAGE="${PROJECT_RESOURCE_PREFIX}-proxy"
    VOLUME_NAME="${PROJECT_RESOURCE_PREFIX}-home"
    NETWORK_NAME="${PROJECT_RESOURCE_PREFIX}-net"
}

initialize_runtime_ids() {
    # Stable port derived from the full project path (49152-65534).
    LOCAL_PORT=$(( 49152 + $(jailbox_project_hash_port_offset "$PROJECT_HASH") ))
    MY_UID=$(id -u)
}
