#!/bin/bash
# Human-readable test output. Keep snapshots, protocol records and assertion
# inputs in their original byte format; timestamp their diagnostic captures.
test_timestamp_stream() {
    local line
    local TZ=UTC
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Buffered stage logs already carry their capture time when replayed.
        if [[ "$line" =~ ^[[:space:]]*\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] ]]; then
            printf '%s\n' "$line"
        else
            printf '[%(%Y-%m-%dT%H:%M:%SZ)T] %s\n' -1 "$line"
        fi
    done
}

# Re-enter the script with its normal shell options and traps. The pipeline
# joins the formatter before returning and preserves failures with pipefail.
test_log_entrypoint() {
    local script="$1"
    shift
    [[ ${JAILBOX_TEST_LOG_SCRIPT:-} != "$script" ]] || return 0
    local result=0
    JAILBOX_TEST_LOG_SCRIPT="$script" bash "$script" "$@" 2>&1 | test_timestamp_stream || result=$?
    exit "$result"
}

# Run in the caller shell so lifecycle worker IDs and editor counters survive.
# A dedicated descriptor lets us join the formatter before assertions read the
# log. Call this where the command's status is already handled explicitly.
test_log_capture() {
    local destination="$1" log_fd log_pid result=0
    shift
    exec {log_fd}> >(test_timestamp_stream > "$destination")
    log_pid=$!
    "$@" >&"$log_fd" 2>&1 || result=$?
    exec {log_fd}>&-
    wait "$log_pid" || return 1
    return "$result"
}
