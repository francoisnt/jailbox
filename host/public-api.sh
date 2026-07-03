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

CLI_FLAGS=(
    doctor
    ssh-config
    --clean
    --help
)

CLI_HELP=(
    "doctor=Report editor and SSH config integration for this project"
    "ssh-config=Print manual SSH config instructions for this project"
    "--clean=Stop/remove jailbox containers, networks, and home volume"
    "--help=Show this help"
)

is_config_scalar_key() {
    local key scalar_key

    key="$1"
    for scalar_key in "${CONFIG_SCALAR_KEYS[@]}"; do
        [ "$key" = "$scalar_key" ] && return 0
    done
    return 1
}

is_config_array_key() {
    local key array_key

    key="$1"
    for array_key in "${CONFIG_ARRAY_KEYS[@]}"; do
        [ "$key" = "$array_key" ] && return 0
    done
    return 1
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
    local arg flag

    arg="$1"
    [ -z "$arg" ] && return 0

    for flag in "${CLI_FLAGS[@]}"; do
        [ "$arg" = "$flag" ] && return 0
    done
    return 1
}

cli_flag_help() {
    local flag entry

    flag="$1"
    for entry in "${CLI_HELP[@]}"; do
        if [ "${entry%%=*}" = "$flag" ]; then
            printf '%s\n' "${entry#*=}"
            return 0
        fi
    done
    return 1
}
