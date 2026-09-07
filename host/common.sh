# Common helpers and configuration loading.

# shellcheck source=host/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-id.sh"
# shellcheck source=host/version.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version.sh"

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
Usage: $(basename "$0") [--config PATH] [init|up|stop|doctor|ssh-config|--clean|--uninstall|--version|--help]

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

command_starts_sandbox() {
    [ -z "${1:-}" ] || [ "${1:-}" = up ]
}

command_launches_editor() {
    [ -z "${1:-}" ]
}

command_requires_config() {
    command_starts_sandbox "${1:-}"
}

# Commands that consume effective configuration. Besides the launch commands,
# ssh-config stays a consumer for now: its proxy SetEnv output depends on
# EGRESS_ALLOW until connection-info supersedes it. stop, doctor, --clean,
# init, --help, and --uninstall never read configuration.
command_consumes_config() {
    case "${1:-}" in
        ""|up|ssh-config) return 0 ;;
        *) return 1 ;;
    esac
}

init_project_config() (
    local destination nested_link tmp_file

    destination="$PROJECT_DIR/jailbox.conf"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        die "jailbox.conf already exists; refusing to overwrite it"
    fi

    tmp_file=""
    trap '[ -z "$tmp_file" ] || rm -f -- "$tmp_file"' EXIT
    trap 'exit 1' HUP INT TERM

    tmp_file=$(mktemp "$PROJECT_DIR/.jailbox.conf.tmp.XXXXXX") || \
        die "could not create temporary project configuration"
    if ! printf '%s\n' \
        '# Additional project paths mounted read-only inside the sandbox.' \
        'READONLY_PATHS=' > "$tmp_file"; then
        die "could not write temporary project configuration"
    fi

    if ln -- "$tmp_file" "$destination" 2>/dev/null; then
        # ln treats an existing directory (and, on some hosts, a symlink to
        # one) as a directory operand. A destination introduced after the
        # check above must not turn publication into a hidden link inside that
        # directory while jailbox reports success.
        if [ "$tmp_file" -ef "$destination" ]; then
            echo "Created $destination"
            return 0
        fi

        nested_link="$destination/${tmp_file##*/}"
        if [ -e "$nested_link" ] && [ "$tmp_file" -ef "$nested_link" ]; then
            rm -f -- "$nested_link"
        fi
    fi

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        die "jailbox.conf already exists; refusing to overwrite it"
    fi
    die "could not publish $destination"
)

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
    validate_editor_config
    validate_machine_config
}

# --- Environment configuration (JAILBOX_CONFIG_*) ------------------------
#
# The canonical machine configuration model: one derived spelling per key
# declared in host/public-api.sh. Names are discovered through name-only
# shell metadata (compgen), never by parsing serialized name=value output,
# because not-yet-validated values may contain newlines that are only
# rejected afterwards with a named diagnostic. Environment entries whose
# names are not valid shell identifiers never become shell parameters and
# are outside the interface.

ENV_CONFIG_PREFIX="JAILBOX_CONFIG_"

environment_config_present() {
    compgen -A export "$ENV_CONFIG_PREFIX" >/dev/null 2>&1
}

environment_config_names() {
    compgen -A export "$ENV_CONFIG_PREFIX" || true
}

validate_environment_value() {
    local name value LC_ALL=C

    name="$1"
    value="$2"
    # Legal values are ordinary bytes including commas and spaces;
    # newline-bearing values are deliberately not representable.
    if [[ "$value" =~ [$'\x01'-$'\x1f'$'\x7f'] ]]; then
        die "configuration value in '$name' contains an ASCII control character"
    fi
}

# Indirect assignment on the declared key name: callers only pass keys from
# the public-API declaration arrays, whose grammar is validated before any
# configuration is interpreted, so the name is never user-controlled.
assign_config_scalar() {
    local key value

    key="$1"
    value="$2"
    printf -v "$key" '%s' "$value"
}

load_environment_config() {
    local name key bare suffix value expected first_missing
    local gap_member count i
    local -a names=() member_names=() items=()
    local -A discovered=() handled=() expected_set=()

    mapfile -t names < <(environment_config_names)

    # Every discovered name is an exported shell parameter, so its charset is
    # already a valid identifier; restrict further to the uppercase namespace
    # grammar before any name is used as an associative-array subscript.
    for name in "${names[@]}"; do
        [[ "$name" =~ ^JAILBOX_CONFIG_[A-Z0-9_]+$ ]] || \
            die "unknown configuration variable '$name'"
        discovered["$name"]=1
    done

    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        name="${ENV_CONFIG_PREFIX}${key}"
        [[ -v discovered[$name] ]] || continue
        # Absent values receive defaults; a present empty scalar stays empty.
        value="${!name}"
        validate_environment_value "$name" "$value"
        assign_config_scalar "$key" "$value"
        handled["$name"]=1
    done

    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        bare="${ENV_CONFIG_PREFIX}${key}"
        member_names=()
        count=0
        for name in "${names[@]}"; do
            [[ "$name" == "${bare}_"* ]] || continue
            suffix="${name#"${bare}_"}"
            [[ "$suffix" =~ ^(0|[1-9][0-9]*)$ ]] || \
                die "malformed configuration array member name '$name' (indices are 0 or nonzero decimal without leading zeros)"
            member_names+=("$name")
            handled["$name"]=1
            # The member count is trusted local state; the caller-supplied
            # suffix is never interpreted through arithmetic or subscripts.
            count=$((count + 1))
        done

        if [[ -v discovered[$bare] ]]; then
            handled["$bare"]=1
            [ "$count" -eq 0 ] || \
                die "configuration array '$key' mixes the bare variable '$bare' with indexed members"
            value="${!bare}"
            [ -z "$value" ] || \
                die "non-empty bare configuration array variable '$bare' (use indexed ${bare}_0.. members; leave it empty for an explicitly empty array)"
            set_config_array "$key"
            continue
        fi
        [ "$count" -gt 0 ] || continue

        # Check the exact expected names _0.._(count-1); any expected name
        # missing means some discovered member sits past the contiguous range.
        items=()
        expected_set=()
        first_missing=""
        for ((i = 0; i < count; i++)); do
            expected="${bare}_${i}"
            expected_set["$expected"]=1
            if [[ ! -v discovered[$expected] ]]; then
                [ -n "$first_missing" ] || first_missing="$expected"
                continue
            fi
            [ -n "$first_missing" ] && continue
            value="${!expected}"
            validate_environment_value "$expected" "$value"
            [ -n "$value" ] || \
                die "empty configuration array member '$expected'"
            items+=("$value")
        done
        if [ -n "$first_missing" ]; then
            gap_member=""
            for name in "${member_names[@]}"; do
                if [[ ! -v expected_set[$name] ]]; then
                    gap_member="$name"
                    break
                fi
            done
            die "configuration array '$key' has a gap: found member '$gap_member' but '$first_missing' is missing"
        fi
        set_config_array "$key" "${items[@]}"
    done

    for name in "${names[@]}"; do
        [[ -v handled[$name] ]] || \
            die "unknown configuration variable '$name'"
    done

    validate_machine_config
}

# Load the effective configuration for a consuming command. Declared
# JAILBOX_CONFIG_* variables are the complete configuration; otherwise a
# temporary in-core adapter parses jailbox.conf into the same effective
# values and runs the same machine validator. The two paths are exclusive:
# never precedence, never merge.
load_effective_config() {
    local command

    command="${1:-}"
    validate_public_api_declaration

    if environment_config_present; then
        [ -z "$CONFIG_PATH_ARG" ] || \
            die "JAILBOX_CONFIG_* environment configuration is present; --config cannot select a file (environment configuration is complete and exclusive)"
        if [ -e "$PROJECT_DIR/jailbox.conf" ] || [ -L "$PROJECT_DIR/jailbox.conf" ]; then
            echo "Notice: $PROJECT_DIR/jailbox.conf is not read because JAILBOX_CONFIG_* environment configuration is present." >&2
        fi
        load_environment_config
        return 0
    fi

    # Temporary file adapter until the frontend layer owns jailbox.conf
    # parsing and composes the environment itself.
    prepare_config_selection "$command"
    load_project_config
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
        if ! is_config_scalar_key "$key" && ! is_config_array_key "$key" && \
            ! is_frontend_scalar_key "$key"; then
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

    # The parser has already established that $key is a declared scalar or
    # frontend key, so the indirect assignment target is declaration-driven.
    assign_config_scalar "$key" "$value"
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

# The effective machine validator: runs on the final configuration values
# whether they came from the environment model or the temporary file adapter.
# Editor validation is frontend-only and belongs to the file path.
validate_machine_config() {
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
