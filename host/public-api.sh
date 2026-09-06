# Public interface declarations.
#
# Changes here drive release version suggestions:
# - Before v1.0.0, adding or removing a config key or CLI flag suggests a minor bump.
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
    "EGRESS_ALLOW="
    "READONLY_PATHS="
)

FRONTEND_DEFAULTS=(
    "EDITOR="
)

CLI_FLAGS_WITH_VALUES=(
    --config
)

CLI_FLAGS_WITHOUT_VALUES=(
    init
    up
    stop
    doctor
    ssh-config
    --clean
    --uninstall
    --help
)

CLI_HELP=(
    "--config=Load configuration from PATH instead of project jailbox.conf"
    "init=Create the default project jailbox.conf"
    "up=Launch the sandbox without opening an editor"
    "stop=Stop and remove this project's jailbox containers"
    "doctor=Report editor and SSH config integration for this project"
    "ssh-config=Print manual SSH config instructions for this project"
    "--clean=Stop/remove jailbox containers, networks, and home volume"
    "--uninstall=Remove this jailbox installation from the host"
    "--help=Show this help"
)

declare -A CONFIG_SCALAR_KEY_SET=()
declare -A CONFIG_ARRAY_KEY_SET=()
declare -A FRONTEND_SCALAR_KEY_SET=()
declare -A CLI_FLAG_SET=()
declare -A CLI_HELP_BY_FLAG=()

initialize_public_api_lookups() {
    local key entry

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

initialize_public_api_lookups

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
    local key

    key="$1"
    shift

    case "$key" in
        EGRESS_ALLOW) EGRESS_ALLOW=("$@") ;;
        READONLY_PATHS) READONLY_PATHS=("$@") ;;
    esac
}

# Scalar assignment is indirect on the declared key name. This is safe
# because keys come only from the declaration arrays above, which
# validate_public_api_declaration restricts to the uppercase identifier
# grammar — never from user input.
apply_config_defaults() {
    local entry key value

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
    local key entry other suffix
    local -A machine_keys=() default_keys=()

    for key in "${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}"; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
            die "public API declares invalid configuration key '$key'"
        [[ ! -v machine_keys[$key] ]] || \
            die "public API declares configuration key '$key' more than once"
        machine_keys["$key"]=1
    done
    for key in "${FRONTEND_SCALAR_KEYS[@]}"; do
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
            die "public API declares invalid frontend key '$key'"
        [[ ! -v machine_keys[$key] ]] || \
            die "public API declares '$key' as both machine and frontend configuration"
    done
    for entry in "${CONFIG_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        [[ -v machine_keys[$key] ]] || \
            die "public API default '$key' has no declared machine key"
        [[ ! -v default_keys[$key] ]] || \
            die "public API declares a default for '$key' more than once"
        default_keys["$key"]=1
    done
    for key in "${!machine_keys[@]}"; do
        [[ -v default_keys[$key] ]] || \
            die "public API key '$key' has no declared default"
    done
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        for other in "${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}" \
            "${FRONTEND_SCALAR_KEYS[@]}"; do
            [[ "$other" == "${key}_"* ]] || continue
            suffix="${other#"${key}_"}"
            if [[ "$suffix" =~ ^(0|[1-9][0-9]*)$ ]]; then
                die "public API key '$other' collides with indexed members of array '$key'"
            fi
        done
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
