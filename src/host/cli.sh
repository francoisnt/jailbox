# Shared CLI syntax, help rendering, and dispatch mappings.
CONFIG_PATH_ARG=${CONFIG_PATH_ARG:-}

# Each handler owns its setup and behavior. Membership comes from public.sh;
# validate_cli_implementation rejects missing or undeclared handlers.
declare -A CLI_COMMAND_HANDLERS=(
    [--no-editor]=run_headless [exec]=run_exec [shell]=run_shell [init]=run_init [up]=run_up [stop]=run_stop
    [config-schema]=run_config_schema [status]=run_status
    [connection-info]=run_connection_info [validate]=run_validate [ssh-config]=run_ssh_config [--clean]=run_clean
    [--uninstall]=run_uninstall [--version]=run_version [--help]=usage
)
declare -A CLI_OPTION_TARGETS=([--config]=CONFIG_PATH_ARG)

usage() {
    local flag synopsis="" separator=""

    for flag in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        synopsis+="[$flag ${CLI_VALUE_NAMES[$flag]}] "
    done
    synopsis+='['
    for flag in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        synopsis+="$separator$flag"
        separator='|'
    done
    synopsis+=']'

    cat <<EOF_USAGE
Usage: $(basename "$0") $synopsis

Launch this project inside a hardened jailbox container.

Options:
EOF_USAGE

    for flag in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        printf '  %-14s %s\n' "$flag ${CLI_VALUE_NAMES[$flag]}" "$(cli_flag_help "$flag")"
    done
    for flag in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        printf '  %-14s %s\n' "$flag" "$(cli_flag_help "$flag")"
    done
}

validate_cli_implementation() {
    local command handler target
    public_api_validate_mapping 'command handlers' CLI_FLAGS_WITHOUT_VALUES CLI_COMMAND_HANDLERS
    public_api_validate_mapping 'option targets' CLI_FLAGS_WITH_VALUES CLI_OPTION_TARGETS
    for command in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
        handler=${CLI_COMMAND_HANDLERS[$command]}
        [[ "$handler" =~ ^[a-z_][a-z0-9_]*$ ]] || public_api_error "invalid handler for '$command'"
    done
    for command in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        target=${CLI_OPTION_TARGETS[$command]}
        [[ "$target" =~ ^[A-Z][A-Z0-9_]*$ ]] || public_api_error "invalid option target for '$command'"
    done
}

parse_args() {
    local option arg
    if cli_command_accepts_arguments "${1:-}"; then
        return 0
    fi
    for option in "${CLI_FLAGS_WITH_VALUES[@]}"; do
        for arg in "$@"; do
            if [[ "$arg" = "$option" ]]; then
                echo "Error: $option must appear before the command" >&2
                usage >&2
                exit 2
            fi
        done
    done
    if [ "$#" -gt 1 ]; then
        echo "Error: unexpected argument: $2" >&2
        usage >&2
        exit 2
    fi
    if ! is_cli_flag_allowed "${1:-}"; then
        usage >&2
        exit 2
    fi
}
