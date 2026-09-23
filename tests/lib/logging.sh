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
    local terminal=false
    [[ ! -t 1 || ${TERM:-dumb} = dumb ]] || terminal=true
    JAILBOX_TEST_PROGRESS_TERMINAL=$terminal JAILBOX_TEST_LOG_SCRIPT="$script" bash "$script" "$@" 2>&1 | test_timestamp_stream | test_display_stream || result=$?
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
    # Only stdout/stderr belong to the command. A detached helper may close
    # those but retain an extra inherited writer, preventing the reader's EOF.
    "$@" >&"$log_fd" 2>&1 {log_fd}>&- || result=$?
    exec {log_fd}>&-
    wait "$log_pid" || return 1
    return "$result"
}

# Only the outermost terminal consumer draws progress. Nested formatters and
# saved logs retain plain timestamped records; workers never move the cursor.
# The optional width exercises terminal rendering without a PTY in unit tests.
test_display_stream() {
    local fixed_width=${1:-} width line message status=""
    if [[ -z "$fixed_width" ]]; then
        if [[ ! -t 1 || ${TERM:-dumb} = dumb ]]; then cat; return; fi
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        message=${line#\[*\] }
        if [[ "$message" = 'Progress: '* ]]; then
            status="$message"
            [[ "$message" != 'Progress: ShellCheck:'* && "$message" != 'Progress: Portable:'* && "$message" != 'Progress: Stages:'* ]] || status=${message#Progress: }
        else
            [[ -z "$status" ]] || printf '\r\033[2K'
            printf '%s\n' "$line"
            if [[ "$message" = 'Lifecycle: '*' cases completed;'* || "$message" = 'FAIL [lifecycle-pool]'* ||
                  "$message" = 'ShellCheck passed'* || "$message" = 'ShellCheck failed'* || "$message" = 'ShellCheck interrupted'* ||
                  "$message" = 'Stages finished:'* || "$message" = 'Portable units:'* ]]; then
                status=""
            fi
        fi
        if [[ -n "$status" ]]; then
            width=$fixed_width
            if [[ -z "$width" ]]; then
                # stdin is the log pipeline; query the actual terminal instead.
                width=$(tput cols 2>/dev/null </dev/tty) || width=80
            fi
            [[ "$width" =~ ^[0-9]+$ && "$width" -gt 1 ]] || width=80
            printf '\r\033[2K%s' "$status"
            # Only keep a transient line when it fits without wrapping. Longer
            # records wrap normally and stay in scrollback with every count.
            if (( ${#status} >= width )); then
                printf '\n'
                status=""
            fi
        fi
    done
    # Leave the cursor on a clean line even if the producer failed early.
    [[ -z "$status" ]] || printf '\r\033[2K%s\n' "$status"
    return 0
}
