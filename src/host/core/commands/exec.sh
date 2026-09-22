# commands — exec

run_exec() {
    local frame
    [[ "${1:-}" != -- ]] || shift
    if [[ $# = 0 || -z "$1" ]]; then
        printf 'Error: jailbox exec requires a command\n' >&2
        return 2
    fi
    require_command base64 || return 1
    require_command tr || return 1
    frame=$(set -o pipefail; printf '%s\0' "$@" | base64 | tr -d '\n') || die 'could not encode jailbox exec arguments'
    # Wire limit shared with container/runtime/bin/jailbox-exec-argv; tested at both ends.
    [[ ${#frame} -le 49152 ]] || die 'argument list too long for jailbox exec'
    [[ -n "$frame" && "$frame" != *[!A-Za-z0-9+/=]* ]] || die 'invalid jailbox exec argument encoding'
    load_environment_config || return 1
    validate_attachment </dev/null >&2 || return 1
    # The validated alphabet contains no shell syntax. The frame travels as a
    # single remote argument; stdin is exclusively the command's byte stream.
    exec ssh -F "$SSH_CONFIG" -T "$CONTAINER_NAME" "/usr/local/bin/jailbox-exec-argv $frame"
}
