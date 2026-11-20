# commands — exec

run_exec() {
    local frame
    [[ "${1:-}" != -- ]] || shift
    if [[ $# = 0 || -z "$1" ]]; then
        printf 'Error: jailbox exec requires a command\n' >&2
        return 2
    fi
    frame=$(encode_ssh_command 'jailbox exec' "$@") || return 1
    load_environment_config || return 1
    validate_attachment </dev/null >&2 || return 1
    exec_ssh_command "$frame"
}
