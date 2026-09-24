#!/bin/bash
# Human-readable test output. Keep snapshots, protocol records and assertion
# inputs in their original byte format; timestamp their diagnostic captures.
# One checkout identity follows nested test tools; copied fixtures must not
# silently switch the meaning of relative paths in an enclosing run's logs.
TEST_LOG_REPOSITORY_ROOT=${JAILBOX_TEST_LOG_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd -P)} || return 1
test_timestamp_stream() {
    local line delimiter
    local root=$TEST_LOG_REPOSITORY_ROOT
    local TZ=UTC
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ${JAILBOX_TEST_FORMAT_COMMANDS:-false} = true &&
              ( "$line" = ::group::* || "$line" = ::endgroup:: ) ]]; then
            printf '%s\n' "$line"
            continue
        fi
        # Only diagnostic text is rewritten, never paths passed to commands or
        # protocol/snapshot files. Quote the pattern to treat root literally.
        line=${line//"$root/"/}
        [[ "$line" != *"$root" ]] || line=${line%"$root"}.
        for delimiter in ' ' '"' "'" ':' ')' $'\t'; do
            line=${line//"$root$delimiter"/".$delimiter"}
        done
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
    [[ ${JAILBOX_TEST_LOG_ACTIVE:-false} != true && ${JAILBOX_TEST_LOG_SCRIPT:-} != "$script" ]] || return 0
    local result=0
    export JAILBOX_TEST_LOG_ROOT="$TEST_LOG_REPOSITORY_ROOT"
    local terminal=false short=false
    [[ "$script" != */tests/run ]] || short=true
    [[ ! -t 1 || ${TERM:-dumb} = dumb ]] || terminal=true
    JAILBOX_TEST_LOG_ACTIVE=true JAILBOX_TEST_PROGRESS_TERMINAL=$terminal JAILBOX_TEST_LOG_SCRIPT="$script" bash "$script" "$@" 2>&1 |
        JAILBOX_TEST_FORMAT_COMMANDS=true test_timestamp_stream |
        JAILBOX_TEST_CONSOLE_SHORT=$short test_display_stream || result=$?
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
    local fixed_width=${1:-} width line message status="" interactive=false
    if [[ -n "$fixed_width" || ( -t 1 && ${TERM:-dumb} != dumb ) ]]; then interactive=true; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ ${JAILBOX_TEST_CONSOLE_SHORT:-false} = true && "$line" =~ ^\[([0-9-]+)T([0-9:]+)Z\] ]]; then
            line="[${BASH_REMATCH[2]}] ${line#*] }"
        fi
        message=${line#\[*\] }
        if [[ "$interactive" = false ]]; then printf '%s\n' "$line"; continue; fi
        if [[ "$message" = 'Progress: '* ]]; then
            status=${line/Progress: /}
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
            if [[ -z "$width" ]]; then width=$(tput cols 2>/dev/null </dev/tty) || width=80; fi
            [[ "$width" =~ ^[0-9]+$ && "$width" -gt 1 ]] || width=80
            printf '\r\033[2K%s' "$status"
            if (( ${#status} >= width )); then printf '\n'; status=""; fi
        fi
    done
    [[ -z "$status" ]] || printf '\r\033[2K%s\n' "$status"
    return 0
}

# Only coordinators emit results or CI control records. Worker logs are already
# timestamped, so command-like diagnostic text is never interpreted by Actions.
test_log_result() {
    local result=$1 task=$2 elapsed=$3
    printf '%-5s %-40s %ss\n' "$result" "$task" "$elapsed"
}

test_log_group() {
    local title=$1 file=$2
    if [[ ${GITHUB_ACTIONS:-false} = true ]]; then
        title=${title//'%'/'%25'}
        title=${title//$'\r'/'%0D'}
        title=${title//$'\n'/'%0A'}
        printf '::group::%s\n' "$title"
    else
        printf 'Details: %s\n' "$title"
    fi
    local result=0
    cat "$file" || result=$?
    [[ ${GITHUB_ACTIONS:-false} != true ]] || printf '::endgroup::\n'
    return "$result"
}

# Each worker has one append-only log. Keep read offsets and partial lines in
# the coordinator; workers never write to the display or move its cursor.
declare -A TEST_LOG_READERS=() TEST_LOG_PARTIAL=()
test_log_drain() {
    local file=$1 kind=$2 label=$3 fd line message stamp
    [[ -f "$file" ]] || return 0
    if [[ ! -v TEST_LOG_READERS[$file] ]]; then
        exec {fd}< "$file" || return 1
        TEST_LOG_READERS[$file]=$fd
        TEST_LOG_PARTIAL[$file]=""
    fi
    fd=${TEST_LOG_READERS[$file]}
    while IFS= read -r line <&"$fd"; do
        line=${TEST_LOG_PARTIAL[$file]}$line
        TEST_LOG_PARTIAL[$file]=""
        stamp=${line%%] *}]
        message=${line#*] }
        case "$kind:$message" in
            stage:'Phase started: '*) printf '%s RUN   %s/%s\n' "$stamp" "$label" "${message#Phase started: }" ;;
            matrix:'PASS ['*|matrix:'FAIL ['*)
                message=${message/ [/  matrix/}
                message=${message/]/}
                printf '%s %s\n' "$stamp" "$message" ;;
        esac
    done
    TEST_LOG_PARTIAL[$file]+=$line
}

test_log_close() {
    local file=$1 fd
    [[ -v TEST_LOG_READERS[$file] ]] || return 0
    fd=${TEST_LOG_READERS[$file]}
    exec {fd}<&-
    unset 'TEST_LOG_READERS[$file]' 'TEST_LOG_PARTIAL[$file]'
}

# Sequential phase boundaries inside an isolated stage worker. Keep explicit
# records alongside timestamped output, including phases stopped by failure.
TEST_PHASE_NAME=""
TEST_PHASE_STARTED=0
TEST_PHASE_LOG=""
test_phase_end() {
    local status=${1:-0} elapsed
    [[ -n "$TEST_PHASE_NAME" ]] || return 0
    elapsed=$((SECONDS - TEST_PHASE_STARTED))
    printf 'Phase finished: %s · %ss · status=%s\n' "$TEST_PHASE_NAME" "$elapsed" "$status" || return 1
    if [[ -n "$TEST_PHASE_LOG" ]]; then
        printf '%s|%s|%s\n' "$TEST_PHASE_NAME" "$elapsed" "$status" >> "$TEST_PHASE_LOG" || return 1
    fi
    TEST_PHASE_NAME=""
}

test_phase_begin() {
    test_phase_end || return 1
    TEST_PHASE_NAME=$1
    TEST_PHASE_STARTED=$SECONDS
    printf 'Phase started: %s\n' "$TEST_PHASE_NAME"
}
