# Shared validation and lookups for public.sh declarations.
# Derived from the command categories during lookup initialization.
CLI_FLAGS_WITHOUT_VALUES=()
declare -A CONFIG_SCALAR_KEY_SET=()
declare -A CONFIG_ARRAY_KEY_SET=()
declare -A FRONTEND_SCALAR_KEY_SET=()
declare -A CLI_FLAG_SET=()
declare -A CLI_HELP_BY_FLAG=()

initialize_public_api_lookups() {
    local key entry

    CLI_FLAGS_WITHOUT_VALUES=("${CLI_LIFECYCLE_COMMANDS[@]}" "${CLI_OTHER_COMMANDS[@]}")
    validate_public_api_declaration
    CONFIG_SCALAR_KEY_SET=()
    CONFIG_ARRAY_KEY_SET=()
    FRONTEND_SCALAR_KEY_SET=()
    CLI_FLAG_SET=()
    CLI_HELP_BY_FLAG=()
    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        CONFIG_SCALAR_KEY_SET["$key"]=1
    done
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        CONFIG_ARRAY_KEY_SET["$key"]=1
    done
    for key in "${FRONTEND_SCALAR_KEYS[@]}"; do
        FRONTEND_SCALAR_KEY_SET["$key"]=1
    done
    for key in "${CLI_FLAGS_WITH_VALUES[@]}" "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        CLI_FLAG_SET["$key"]=1
    done
    for entry in "${CLI_HELP[@]}"; do
        CLI_HELP_BY_FLAG["${entry%%=*}"]="${entry#*=}"
    done
}

is_config_scalar_key() {
    local key

    key="$1"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ -v CONFIG_SCALAR_KEY_SET[$key] ]]
}

is_config_array_key() {
    local key

    key="$1"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ -v CONFIG_ARRAY_KEY_SET[$key] ]]
}

is_frontend_scalar_key() {
    local key

    key="$1"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ -v FRONTEND_SCALAR_KEY_SET[$key] ]]
}

# Declaration integrity for the derived machine namespace: every declared key
# is unique, scalar/array classes are disjoint, defaults cover exactly the
# declared machine keys, and no declared key spells another array key's
# indexed member. Runs before configuration is interpreted.
validate_public_api_declaration() {
    local key other suffix
    local -A machine_keys=()
    # shellcheck disable=SC2034 # Consumed through a nameref.
    local -a all_machine_keys=("${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}")

    for key in "${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}"; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
            public_api_error "public API declares invalid configuration key '$key'"
        [[ ! -v machine_keys[$key] ]] || \
            public_api_error "public API declares configuration key '$key' more than once"
        machine_keys["$key"]=1
    done
    for key in "${FRONTEND_SCALAR_KEYS[@]}"; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
            public_api_error "public API declares invalid frontend key '$key'"
        [[ ! -v machine_keys[$key] ]] || \
            public_api_error "public API declares '$key' as both machine and frontend configuration"
    done
    public_api_validate_mapping 'configuration defaults' all_machine_keys CONFIG_DEFAULTS allow-empty
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        for other in "${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}" \
            "${FRONTEND_SCALAR_KEYS[@]}"; do
            [[ "$other" == "${key}_"* ]] || continue
            suffix="${other#"${key}_"}"
            if [[ "$suffix" =~ ^(0|[1-9][0-9]*)$ ]]; then
                public_api_error "public API key '$other' collides with indexed members of array '$key'"
            fi
        done
    done
    # shellcheck disable=SC2034 # Consumed through a nameref.
    local -a all_cli=("${CLI_FLAGS_WITH_VALUES[@]}" "${CLI_FLAGS_WITHOUT_VALUES[@]}")
    public_api_validate_mapping 'CLI help' all_cli CLI_HELP
    public_api_validate_mapping 'option value names' CLI_FLAGS_WITH_VALUES CLI_VALUE_NAMES
    for key in "${all_cli[@]}"; do
        [[ "$key" =~ ^-{0,2}[A-Za-z][A-Za-z0-9-]*$ ]] || public_api_error "invalid CLI name '$key'"
    done
    public_api_validate_mapping 'frontend defaults' FRONTEND_SCALAR_KEYS FRONTEND_DEFAULTS allow-empty
    for key in "${CLI_ARGUMENT_COMMANDS[@]}"; do
        [[ " ${CLI_FLAGS_WITHOUT_VALUES[*]} " = *" $key "* ]] || public_api_error "argument command '$key' is undeclared"
    done
}

cli_command_accepts_arguments() {
    local command
    for command in "${CLI_ARGUMENT_COMMANDS[@]}"; do
        [[ "$command" != "${1:-}" ]] || return 0
    done
    return 1
}

public_api_error() {
    printf 'Error: public API: %s\n' "$*" >&2
    exit 1
}

# Validate an associative map or an indexed array of KEY=value records against
# a declaration list. Values must be nonempty unless allow-empty is supplied
# (for defaults). Domain-specific value checks remain with the consumer.
public_api_validate_mapping() {
    local label="$1" key entry declaration empty_policy="${4:-nonempty}"
    local -n api_members="$2" api_mapping="$3"
    local -a api_records=()
    local -A declared=() mapped=()
    [[ "$empty_policy" = nonempty || "$empty_policy" = allow-empty ]] || public_api_error "$label: invalid empty-value policy"
    declaration=$(declare -p "$3" 2>/dev/null) || public_api_error "$label: missing mapping table '$3'"
    if [[ "$declaration" =~ ^declare\ -[^[:space:]]*A ]]; then
        for key in "${!api_mapping[@]}"; do
            [[ "$key" =~ ^(-{1,2})?[A-Za-z][A-Za-z0-9_-]*$ ]] || public_api_error "$label: invalid mapping name '$key'"
            api_records+=("$key=${api_mapping[$key]}")
        done
    elif [[ "$declaration" =~ ^declare\ -[^[:space:]]*a ]]; then
        api_records=("${api_mapping[@]}")
    else
        public_api_error "$label: mapping table must be an array"
    fi
    for key in "${api_members[@]}"; do
        [[ "$key" =~ ^(-{1,2})?[A-Za-z][A-Za-z0-9_-]*$ ]] || public_api_error "$label: invalid name '$key'"
        [[ ! -v declared[$key] ]] || public_api_error "$label: duplicate declaration '$key'"
        declared["$key"]=1
    done
    for entry in "${api_records[@]}"; do
        key=${entry%%=*}
        [[ "$entry" = *=* && "$key" =~ ^(-{1,2})?[A-Za-z][A-Za-z0-9_-]*$ ]] || public_api_error "$label: invalid entry '$entry'"
        [[ -v declared[$key] ]] || public_api_error "$label: undeclared mapping '$key'"
        [[ ! -v mapped[$key] ]] || public_api_error "$label: duplicate mapping '$key'"
        [[ "$empty_policy" = allow-empty || -n "${entry#*=}" ]] || public_api_error "$label: empty mapping '$key'"
        mapped["$key"]=1
    done
    for key in "${api_members[@]}"; do
        [[ -v mapped[$key] ]] || public_api_error "$label: missing mapping '$key'"
    done
}

is_cli_flag_allowed() {
    local arg

    arg="$1"
    [ -z "$arg" ] && return 0
    [[ "$arg" =~ ^-{0,2}[A-Za-z][A-Za-z0-9-]*$ ]] || return 1
    [[ -v CLI_FLAG_SET[$arg] ]]
}

cli_flag_help() {
    local flag

    flag="$1"
    [[ "$flag" =~ ^-{0,2}[A-Za-z][A-Za-z0-9-]*$ ]] || return 1
    [[ -v CLI_HELP_BY_FLAG[$flag] ]] || return 1
    printf '%s\n' "${CLI_HELP_BY_FLAG[$flag]}"
}
