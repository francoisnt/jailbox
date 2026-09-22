# commands — shell

# Command and terminal attachment. Only the final SSH process inherits input.
run_shell() {
    [[ -t 0 && -t 1 ]] || die 'jailbox shell requires a terminal on both stdin and stdout'
    load_environment_config || return 1
    validate_attachment </dev/null >&2 || return 1
    # SSH owns terminal modes, resize forwarding, signals, and the exit status.
    # Login startup files see this initial directory and the SSH environment;
    # their subsequent customizations remain under the user's control.
    exec ssh -F "$SSH_CONFIG" -tt -- "$CONTAINER_NAME" 'cd /home/jailbox/project && exec bash -il'
}
