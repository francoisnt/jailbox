# Public interface declarations.
#
# Changes here drive release version suggestions:
# - Before v1.0.0, adding or removing a config key or CLI flag suggests a minor bump.
# - After v1.0.0, removing a config key or CLI flag suggests a major bump.
# - After v1.0.0, adding a config key or CLI flag suggests a minor bump.
# - Other changes suggest a patch bump.

CONFIG_SCALAR_KEYS=(
    DEV_IMAGE
    DEV_CONTAINERFILE
    DEV_BUILD_CONTEXT
    DEV_TARGET_STAGE
    EDITOR
)

CONFIG_ARRAY_KEYS=(
    EGRESS_ALLOW
    READONLY_EXTRA
)

CONFIG_DEFAULTS=(
    "DEV_IMAGE="
    "DEV_CONTAINERFILE="
    "DEV_BUILD_CONTEXT="
    "DEV_TARGET_STAGE="
    "EDITOR="
    "EGRESS_ALLOW="
    "READONLY_EXTRA="
)

CLI_FLAGS_WITH_VALUES=(
    --config
)

CLI_FLAGS_WITHOUT_VALUES=(
    doctor
    ssh-config
    --clean
    --uninstall
    --help
)

CLI_HELP=(
    "--config=Load configuration from PATH instead of project jailbox.conf"
    "doctor=Report editor and SSH config integration for this project"
    "ssh-config=Print manual SSH config instructions for this project"
    "--clean=Stop/remove jailbox containers, networks, and home volume"
    "--uninstall=Remove this jailbox installation from the host"
    "--help=Show this help"
)

declare -A CONFIG_SCALAR_KEY_SET=()
declare -A CONFIG_ARRAY_KEY_SET=()
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

apply_config_defaults() {
    local entry key value

    for entry in "${CONFIG_DEFAULTS[@]}"; do
        key="${entry%%=*}"
        value="${entry#*=}"
        case "$key" in
            DEV_IMAGE) DEV_IMAGE="$value" ;;
            DEV_CONTAINERFILE) DEV_CONTAINERFILE="$value" ;;
            DEV_BUILD_CONTEXT) DEV_BUILD_CONTEXT="$value" ;;
            DEV_TARGET_STAGE) DEV_TARGET_STAGE="$value" ;;
            EDITOR) EDITOR="$value" ;;
            EGRESS_ALLOW)
                EGRESS_ALLOW=()
                ;;
            READONLY_EXTRA)
                READONLY_EXTRA=()
                ;;
        esac
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
