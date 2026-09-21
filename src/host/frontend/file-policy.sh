# File parsing and composition for public frontend workflows.
# This module depends only on shared public declarations, never core state.
# shellcheck source=src/public-api.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/api-support.sh"
initialize_public_api_lookups

declare -A FRONTEND_VALUES=()
FRONTEND_PROJECT=""
FRONTEND_CONFIG=""
FRONTEND_ANCHORS=()
FRONTEND_ENVIRONMENT=()
FRONTEND_POLICY_READY=0

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

config_die() {
    die "invalid config '$FRONTEND_CONFIG' line $1: $2"
}

# Values have already passed the declaration and atom grammar checks.
set_file_scalar() {
    FRONTEND_VALUES["$1"]=$2
}

set_file_array() {
    local key=$1 IFS=,
    shift
    FRONTEND_VALUES["$key"]="$*"
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
    FRONTEND_VALUES=()
    local prefix rest LC_ALL=C

    # read -d NUL detects the byte before line-oriented Bash reads discard it.
    if IFS= read -r -d '' prefix < "$1"; then
        line_no=1
        rest=$prefix
        while [[ "$rest" == *$'\n'* ]]; do
            line_no=$((line_no + 1))
            rest=${rest#*$'\n'}
        done
        config_die "$line_no" "NUL byte in file"
    fi

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
    [[ -v FRONTEND_VALUES[$key] ]]
}

validate_config_value() {
    local value line_no

    value="$1"
    line_no="$2"

    if [[ "$value" =~ [$'\x01'-$'\x1f'$'\x7f'] ]]; then
        config_die "$line_no" "ASCII control character in value"
    fi
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

    if [ "${#value}" -ge 2 ] && { { [[ "$first" = '"' && "$last" = '"' ]]; } || { [[ "$first" = "'" && "$last" = "'" ]]; }; }; then
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
    set_file_scalar "$key" "$value"
}

parse_config_array() {
    local key raw_value line_no item items parts

    key="$1"
    raw_value="$2"
    line_no="$3"
    raw_value=$(unquote_config_value "$raw_value" "$line_no") || return $?
    items=()

    if [ -z "$raw_value" ]; then
        set_file_array "$key"
        return 0
    fi

    # Arrays are comma-separated data, not Bash arrays. That keeps the only
    # list syntax independent of shell parsing while remaining easy to edit.
    [[ "$raw_value" != *, ]] || config_die "$line_no" "empty list item for '$key'"
    IFS=',' read -ra parts <<< "$raw_value"
    for item in "${parts[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || config_die "$line_no" "empty list item for '$key'"
        item=$(unquote_config_value "$item" "$line_no") || return $?
        validate_config_value "$item" "$line_no"
        items+=("$item")
    done

    set_file_array "$key" "${items[@]}"
}

# Check each lexical component before realpath can hide a symlink, including
# a symlink followed by '..'. Relative selected paths are relative to the caller.
check_config_path() {
    local path=$1 current component LC_ALL=C
    local -a components=()
    [[ ! "$path" =~ [$'\x01'-$'\x1f'$'\x7f'] ]] || die 'path contains an ASCII control character'
    case "$path" in
        /*) current=/ ;;
        *) current=$PWD ;;
    esac
    IFS=/ read -ra components <<< "$path"
    for component in "${components[@]}"; do
        case "$component" in
            ''|.) continue ;;
            ..) current=${current%/*}; current=${current:-/}; continue ;;
        esac
        current=${current%/}/$component
        [[ ! -L "$current" ]] || die "config path contains a symlink: $path"
    done
}

resolve_config_file() {
    local path=$1 canonical
    check_config_path "$path" || return $?
    [[ -f "$path" && -r "$path" ]] || die "config path is not a readable regular file: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize config path: $path"
    printf '%s\n' "$canonical"
}

# Resolve and parse once. Both explicit validation and launch require the
# default anchor, including when the selected policy lives outside the project.
load_file_policy() {
    local project=$1 selected=${2:-} default key
    FRONTEND_POLICY_READY=0
    FRONTEND_VALUES=()
    FRONTEND_ANCHORS=()
    FRONTEND_ENVIRONMENT=()
    FRONTEND_PROJECT=$(cd -- "$project" && pwd -P) || die 'cannot resolve project directory'
    check_config_path "$FRONTEND_PROJECT" || return $?
    default=$FRONTEND_PROJECT/jailbox.conf
    [[ -e "$default" || -L "$default" ]] || die "Project is not initialized: jailbox.conf is required even with --config. Run 'jailbox init'."
    default=$(resolve_config_file "$default") || return $?
    FRONTEND_ANCHORS+=(jailbox.conf)
    FRONTEND_CONFIG=$(resolve_config_file "${selected:-$default}") || return $?
    if [[ "$FRONTEND_CONFIG" != "$default" && "$FRONTEND_CONFIG" == "$FRONTEND_PROJECT/"* ]]; then
        FRONTEND_ANCHORS+=("${FRONTEND_CONFIG#"$FRONTEND_PROJECT"/}")
    fi
    parse_config_file "$FRONTEND_CONFIG" || return $?
    # Every file-only key needs a validator; new machine keys map generically.
    # shellcheck disable=SC2034 # Read through the public mapping validator.
    local -a validators=(EDITOR=editor)
    public_api_validate_mapping 'frontend file validators' FRONTEND_SCALAR_KEYS validators
    for key in "${FRONTEND_SCALAR_KEYS[@]}"; do
        case "$key" in
            EDITOR)
                case "${FRONTEND_VALUES[$key]-}" in
                    ''|code|codium) ;;
                    *) die "invalid EDITOR in '$FRONTEND_CONFIG'; file selection must be codium or code; resolved editor: none" ;;
                esac
                ;;
        esac
    done
}

# Compose a snapshot for identical environments across public child calls.
# Arguments are the editor owner's bootstrap destinations; headless callers
# provide none. No machine-policy validation is duplicated here.
# Optional arguments come from the editor frontend; headless callers pass none.
# shellcheck disable=SC2120
compose_machine_environment() {
    local entry key value item index complete=0
    local -a environment=() ignored=() items=() unique=()
    FRONTEND_POLICY_READY=0
    [[ -n "$FRONTEND_CONFIG" && -n "${FRONTEND_ANCHORS[*]-}" ]] || die 'file policy has not been loaded'
    # env's success sentinel is checked: process-substitution status alone
    # cannot establish that the complete environment was read successfully.
    while IFS= read -r -d '' entry; do
        if [[ "$entry" == frontend-environment-complete ]]; then
            complete=1
            break
        fi
        case "$entry" in
            JAILBOX_CONFIG_*=*) ignored+=("${entry%%=*}") ;;
            *) environment+=("$entry") ;;
        esac
    done < <(env -0 || exit; printf 'frontend-environment-complete\0')
    [[ "$complete" == 1 ]] || die 'could not read inherited environment'
    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        [[ -v FRONTEND_VALUES[$key] ]] || continue
        environment+=("JAILBOX_CONFIG_$key=${FRONTEND_VALUES[$key]}")
    done
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        value=${FRONTEND_VALUES[$key]-}
        items=()
        [[ -z "$value" ]] || IFS=, read -ra items <<< "$value"
        case "$key" in
            EGRESS_ALLOW) [[ -z "$value" ]] || items+=("$@") ;;
            READONLY_PATHS) items+=("${FRONTEND_ANCHORS[@]}") ;;
        esac
        unique=()
        for item in "${items[@]}"; do
            # Exact comparisons avoid associative subscripts from file data.
            for value in "${unique[@]}"; do
                [[ "$item" != "$value" ]] || continue 2
            done
            unique+=("$item")
        done
        index=0
        for item in "${unique[@]}"; do
            environment+=("JAILBOX_CONFIG_${key}_$index=$item")
            index=$((index + 1))
        done
        if [[ -z "${unique[*]-}" && -v FRONTEND_VALUES[$key] ]]; then
            environment+=("JAILBOX_CONFIG_$key=")
        fi
    done
    if [[ -n "${ignored[*]-}" ]]; then
        printf 'Notice: ignoring inherited machine configuration:' >&2
        printf ' %q' "${ignored[@]}" >&2
        printf '; use jailbox up for environment configuration.\n' >&2
    fi
    FRONTEND_ENVIRONMENT=("${environment[@]}")
    FRONTEND_POLICY_READY=1
}

run_core_command() (
    local executable=$1
    shift
    [[ "$FRONTEND_POLICY_READY" == 1 ]] || die 'machine policy has not been composed'
    cd -- "$FRONTEND_PROJECT" || die 'cannot enter project directory'
    env -i -- "${FRONTEND_ENVIRONMENT[@]}" "$executable" "$@"
)

# Public executable, project, selected file. No editor or lifecycle calls.
validate_file_config() {
    local executable=$1
    load_file_policy "$2" "$3" || return $?
    # shellcheck disable=SC2119 # Explicitly headless composition.
    compose_machine_environment || return $?
    run_core_command "$executable" validate
}
