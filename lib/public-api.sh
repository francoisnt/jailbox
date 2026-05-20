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
    EXTRA_PACKAGES
    REMOTE_PATH
    CLAUDE_INSTALL_SHA256
    AIDER_VERSION
    DEV_USER
)

CONFIG_ARRAY_KEYS=(
    AI_TOOLS
    EGRESS_ALLOW
)

CONFIG_DEFAULTS=(
    "DEV_IMAGE="
    "DEV_CONTAINERFILE="
    "DEV_BUILD_CONTEXT="
    "DEV_TARGET_STAGE="
    "EXTRA_PACKAGES="
    "REMOTE_PATH=/home/devuser/project"  # sentinel: re-derived from DEV_USER in load_project_config
    "CLAUDE_INSTALL_SHA256="
    "AIDER_VERSION="
    "DEV_USER=devuser"
    "AI_TOOLS=claude"
    "EGRESS_ALLOW="
)

CLI_FLAGS=(
    --clean
    --help
)

CLI_HELP=(
    "--clean=Stop/remove jailbox containers, networks, and home volume"
    "--help=Show this help"
)

public_api_join_by_pipe() {
    local item output

    output=""
    for item in "$@"; do
        if [ -z "$output" ]; then
            output="$item"
        else
            output="$output|$item"
        fi
    done
    printf '%s\n' "$output"
}

config_scalar_key_regex() {
    public_api_join_by_pipe "${CONFIG_SCALAR_KEYS[@]}"
}

config_array_key_regex() {
    public_api_join_by_pipe "${CONFIG_ARRAY_KEYS[@]}"
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
        if is_config_array_key "$key"; then
            set_config_array_default "$key" "$value"
        else
            printf -v "$key" '%s' "$value"
        fi
    done
}

set_config_array_default() {
    local key value

    key="$1"
    value="$2"

    if [ -z "$value" ]; then
        eval "$key=()"
    else
        # Values are repo-controlled defaults from CONFIG_DEFAULTS.
        eval "$key=($value)"
    fi
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
