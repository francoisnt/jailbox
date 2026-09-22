# checks — host

die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# The derived port can collide with an unrelated listener; fail with a clear
# message instead of a confusing podman bind error or wait_for_ssh timeout.
check_local_port_available() {
    # Only the caller that has validated the running container, its published
    # endpoint, and pinned SSH authentication can exempt its own listener.
    [ "${1:-}" != running ] || return 0
    if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then
        die "local port $LOCAL_PORT is already in use by another process. jailbox derives this port from the project path; stop the conflicting listener and relaunch."
    fi
}

host_preflight() {
    require_command podman
    require_command cksum
    require_command ssh
    require_command ssh-keygen
    require_command realpath
}
