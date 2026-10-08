# Per-command evidence survives later setup, fault, and recovery commands.
LIFECYCLE_COMMAND_SEQUENCE=0
LIFECYCLE_COMMAND_LOG=""

lifecycle_command_log_begin() {
    LIFECYCLE_COMMAND_SEQUENCE=$((LIFECYCLE_COMMAND_SEQUENCE + 1))
    printf -v LIFECYCLE_COMMAND_LOG '%s/%s.command.%04d' "$LOG" "$CASE_KEY" "$LIFECYCLE_COMMAND_SEQUENCE"
    local command
    printf -v command '%q ' "$@"
    printf '%s\t%s\n' "${LIFECYCLE_COMMAND_LOG##*/}" "$command" >> "$LOG/command-index.tsv"
}

lifecycle_capture() {
    local result=0
    lifecycle_command_log_begin "$@" || return 1
    test_log_capture "$LIFECYCLE_COMMAND_LOG" "$@" || result=$?
    # Existing assertions inspect the latest command; numbered logs are the
    # permanent evidence, including when the next command fails.
    cp -- "$LIFECYCLE_COMMAND_LOG" "$LOG/$CASE_KEY.command" || return 1
    printf '%s\texit=%s\n' "${LIFECYCLE_COMMAND_LOG##*/}" "$result" >> "$LOG/command-index.tsv" || return 1
    return "$result"
}
