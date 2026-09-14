# Public interface declarations.
#
# Changes here drive release version suggestions:
# - Before v1.0.0, additions suggest patch and removals suggest minor.
# - After v1.0.0, removing a config key or CLI flag suggests a major bump.
# - After v1.0.0, adding a config key or CLI flag suggests a minor bump.
# - Other changes suggest a patch bump.

# Machine configuration keys. Each declared key has exactly one derived
# environment spelling: KEY -> JAILBOX_CONFIG_KEY (scalars) or contiguous
# JAILBOX_CONFIG_KEY_0.. members / a bare empty variable (arrays). The
# namespace is declared here once; adding or removing a key changes the
# derived interface.
CONFIG_SCALAR_KEYS=(
    DEV_IMAGE
    DEV_CONTAINERFILE
    DEV_BUILD_CONTEXT
    DEV_TARGET_STAGE
    MEMORY_LIMIT
    CPU_LIMIT
    PIDS_LIMIT
    EPHEMERAL_HOME
)

CONFIG_ARRAY_KEYS=(
    EGRESS_ALLOW
    READONLY_PATHS
)

# Frontend-only keys: accepted in jailbox.conf for the human editor workflow,
# never part of the JAILBOX_CONFIG_* machine namespace.
FRONTEND_SCALAR_KEYS=(
    EDITOR
)

# Resource-limit defaults are literal effective values, not launch-time
# fallbacks: an absent key and an explicitly spelled default are the same
# configuration (and the same digest once the digest lands).
CONFIG_DEFAULTS=(
    "DEV_IMAGE="
    "DEV_CONTAINERFILE="
    "DEV_BUILD_CONTEXT="
    "DEV_TARGET_STAGE="
    "MEMORY_LIMIT=4g"
    "CPU_LIMIT=2"
    "PIDS_LIMIT=256"
    "EPHEMERAL_HOME=false"
    "EGRESS_ALLOW="
    "READONLY_PATHS="
)

FRONTEND_DEFAULTS=(
    "EDITOR="
)

CLI_FLAGS_WITH_VALUES=(
    --config
)
declare -A CLI_VALUE_NAMES=([--config]=PATH)

# Commands that manage sandbox containers, networks, and home state. The bare
# editor launch uses up's lifecycle behavior. Project initialization and host
# installation management belong to the other command category.
CLI_LIFECYCLE_COMMANDS=(
    up
    stop
    --clean
)

CLI_OTHER_COMMANDS=(
    init
    config-schema
    status
    doctor
    ssh-config
    --uninstall
    --version
    --help
)

CLI_HELP=(
    "--version=Show the build version without reading configuration"
    "--config=Load configuration from PATH instead of project jailbox.conf"
    "init=Create the default project jailbox.conf"
    "config-schema=Print machine configuration key names and types"
    "status=Print this project's resource inventory state"
    "up=Launch the sandbox without opening an editor"
    "stop=Stop and remove this project's jailbox containers, networks, and ephemeral home"
    "doctor=Report editor and SSH config integration for this project"
    "ssh-config=Print manual SSH config instructions for this project"
    "--clean=Permanently delete this project's containers, networks, home, runtime state, and derived images"
    "--uninstall=Remove this jailbox installation from the host"
    "--help=Show this help"
)

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

set_config_array() {
    is_config_array_key "$1" || public_api_error "unknown array key '$1'"
    # shellcheck disable=SC2178 # Nameref to the validated array, not a scalar.
    local -n config_array_target="$1"
    shift
    # shellcheck disable=SC2034 # Assignment through a validated nameref.
    config_array_target=("$@")
}

# Scalar assignment is indirect on the declared key name. This is safe
# because keys come only from the declaration arrays above, which
# validate_public_api_declaration restricts to the uppercase identifier
# grammar — never from user input.
apply_config_defaults() {
    local entry key value

    validate_public_api_declaration
    for entry in "${CONFIG_DEFAULTS[@]}" "${FRONTEND_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        if is_config_array_key "$key"; then
            set_config_array "$key"
        else
            printf -v "$key" '%s' "$value"
        fi
    done
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

run_config_schema() {
    local key

    validate_public_api_declaration
    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        printf '%s\tscalar\n' "$key"
    done
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        printf '%s\tarray\n' "$key"
    done
}

initialize_public_api_lookups
