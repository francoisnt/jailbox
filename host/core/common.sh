# Common helpers and configuration loading.

# shellcheck source=host/core/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-id.sh"
# shellcheck source=host/core/version.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version.sh"

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

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Print the canonical project-relative spelling of an existing path. Return
# 1 for an outside path and 2 when containment cannot be established. Callers
# may omit an outside input's project mount, but must not ignore a failed read.
canonical_project_relative_path() {
    local candidate project_abs candidate_abs

    candidate="$1"
    project_abs=$(realpath -- "$PROJECT_DIR" 2>/dev/null) || return 2
    candidate_abs=$(realpath -- "$candidate" 2>/dev/null) || return 2
    [ -e "$candidate_abs" ] || return 2
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

# ASCII control characters are never valid in a configuration value or in a
# path jailbox encodes into a TAB- or newline-delimited record. NUL cannot
# appear in a Bash string, so this predicate covers every byte the framing
# cannot represent unambiguously.
contains_control_character() {
    local value LC_ALL=C

    value="$1"
    [[ "$value" =~ [$'\x01'-$'\x1f'$'\x7f'] ]]
}

# Refuse a path before it reaches delimiter-based classification or digest
# serialization. The offending value is deliberately not echoed back: it is
# exactly the string whose control characters would corrupt that output.
reject_control_characters() {
    local description

    description="$1"
    if contains_control_character "$2"; then
        die "$description path contains an ASCII control character"
    fi
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
    local path description canonical relative status=0

    path="$1"
    description="$2"
    reject_control_characters "$description" "$path"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -f "$path" ] || die "$description path is not a regular file: $path"
    [ -r "$path" ] || die "$description path is not readable: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    reject_control_characters "canonical $description" "$canonical"
    relative=""
    relative=$(canonical_project_relative_path "$canonical") || status=$?
    case "$status" in
        0) ;;
        1) relative="" ;;
        *) die "cannot establish project containment for $description path: $path" ;;
    esac
    printf '%s\t%s\n' "$canonical" "$relative"
}

classify_trusted_directory() {
    local path description canonical

    path="$1"
    description="$2"
    reject_control_characters "$description" "$path"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -d "$path" ] || die "$description path is not a directory: $path"
    [[ -r "$path" && -x "$path" ]] || die "$description path is not accessible: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    reject_control_characters "canonical $description" "$canonical"
    printf '%s\n' "$canonical"
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

environment_config_names() {
    compgen -A export "$ENV_CONFIG_PREFIX" || true
}

validate_environment_value() {
    local name value LC_ALL=C

    name="$1"
    value="$2"
    # Legal values are ordinary bytes including commas and spaces;
    # newline-bearing values are deliberately not representable.
    if contains_control_character "$value"; then
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

validate_machine_config() {
    case "$EPHEMERAL_HOME" in
        true|false) ;;
        *) die "invalid EPHEMERAL_HOME (expected exactly true or false)" ;;
    esac
    validate_egress_allow
    validate_readonly_paths_lexical
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
    # Identity is derived before any preflight, so a host with neither
    # SHA-256 tool fails here — with the dependency diagnostic the hash helper
    # prints — instead of continuing with an empty or partial name.
    PROJECT_HASH=$(project_path_hash) || die "could not derive project identity"
    # Podman resources carry the project name for readability; the hash of
    # the full path remains the identity. State directories below stay keyed
    # on the hash alone.
    PROJECT_RESOURCE_PREFIX=$(jailbox_resource_prefix_for_path "$PROJECT_DIR") || die "could not derive project resource identity"
    PROJECT_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox"
    CONTAINER_NAME="${PROJECT_RESOURCE_PREFIX}"
    PROXY_NAME="${PROJECT_RESOURCE_PREFIX}-proxy"
    PROXY_IMAGE="${PROJECT_RESOURCE_PREFIX}-proxy"
    VOLUME_NAME="${PROJECT_RESOURCE_PREFIX}-home"
    NETWORK_NAME="${PROJECT_RESOURCE_PREFIX}-net"
}

initialize_runtime_ids() {
    local offset

    # Stable port derived from the full project path (49152-65534).
    offset=$(jailbox_project_hash_port_offset "$PROJECT_HASH") || exit 1
    LOCAL_PORT=$(( 49152 + offset ))
    MY_UID=$(id -u)
}
