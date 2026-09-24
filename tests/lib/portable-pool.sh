#!/bin/bash
# Scheduling policy is separate from discovery: unreviewed suites are exclusive.
# shellcheck source=scripts/lib/process-pool.sh
source "$JAILBOX_DIR/scripts/lib/process-pool.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$JAILBOX_DIR/scripts/lib/worker-resources.sh"

portable_unit_pool() (
    local run=$1 workers=$2 catalog file name status=0 passed=0 failed=0 completed=0 total
    local started=$SECONDS last_progress=-15
    local -A parallel=()
    catalog=$(find "$SCRIPT_DIR/unit" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort) || return 1
    total=0
    while IFS= read -r file; do
        [[ -z "$file" ]] || total=$((total + 1))
    done <<< "$catalog"
    while IFS= read -r name; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        [[ "$name" =~ ^[a-z0-9-]+\.sh$ && -z ${parallel[$name]-} && -f "$SCRIPT_DIR/unit/$name" ]] || {
            printf 'Invalid portable isolation entry: %s\n' "$name" >&2; return 1;
        }
        parallel[$name]=true
    done < "$SCRIPT_DIR/lib/portable-parallel.txt"

    # shellcheck disable=SC2329 # Operation-scoped EXIT cleanup.
    portable_pool_cleanup() {
        local result=$?
        trap - EXIT
        trap '' HUP INT TERM
        process_pool_cancel || result=1
        printf '%s|%s\n' "$passed" "$failed" > "$run/summary" || result=1
        printf 'Portable units: %s/%s completed · %ss · logs: %s\n' "$completed" "$total" "$((SECONDS - started))" "$run"
        exit "$result"
    }
    trap portable_pool_cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_report() {
        local suite=$1 result=$2 elapsed=$3
        printf '%s|%s|%s\n' "$suite" "$result" "$elapsed" >> "$run/timings" || return 1
        if ((result == 0)); then
            passed=$((passed + 1))
            test_log_result PASS "portable/${suite%.sh}" "$elapsed"
        else
            failed=$((failed + 1))
            test_log_result FAIL "portable/${suite%.sh}" "$elapsed"
        fi
        if ((result != 0)) || [[ ${GITHUB_ACTIONS:-false} = true ]]; then
            test_log_group "portable/${suite%.sh}" "$run/$suite.log" || return 1
        fi
        completed=$((completed + 1))
    }
    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_progress() {
        local elapsed=$((SECONDS - started)) interval=15
        [[ ${JAILBOX_TEST_PROGRESS_TERMINAL:-false} != true ]] || interval=1
        ((elapsed - last_progress >= interval)) || return 0
        last_progress=$elapsed
        printf 'Progress: Portable: %s/%s done · %s running · %s failed · %ss\n' \
            "$completed" "$total" "${#PROCESS_POOL_LABELS[@]}" "$failed" "$elapsed"
    }
    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_launch() {
        local suite=$1
        [[ "$PROCESS_POOL_RESULT" = 0 ]] || return 1
        # Nested auto-sized tools must not each claim the host's whole budget.
        JAILBOX_TEST_JOB_LIMIT=1 python3 "$SCRIPT_DIR/lib/run-suite.py" bash "$SCRIPT_DIR/unit/$suite" \
            > "$run/$suite.log" 2>&1 &
        PROCESS_POOL_LAUNCHED_PID=$!
    }
    process_pool_init "$workers" portable_pool_report portable_pool_progress || return 1
    printf 'Portable unit workers: %s · logs: %s\n' "$workers" "$run"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        name=${file##*/}
        [[ "$name" =~ ^[a-z0-9-]+\.sh$ ]] || return 1
        if [[ -z ${parallel[$name]-} ]]; then
            process_pool_wait || { status=1; break; }
        fi
        process_pool_submit "$name" portable_pool_launch "$name" || { status=1; break; }
        if [[ -z ${parallel[$name]-} ]]; then
            process_pool_wait || { status=1; break; }
        fi
    done <<< "$catalog"
    process_pool_wait || status=1
    return "$status"
)

run_portable_unit_suites() {
    local run workers result=0 passed=0 failed=0
    workers=$(worker_tool_budget portable) || return 1
    mkdir -p "$JAILBOX_DIR/testlog" || return 1
    run=$(mktemp -d "$JAILBOX_DIR/testlog/portable.XXXXXXXX") || return 1
    portable_unit_pool "$run" "$workers" || result=$?
    if [[ -f "$run/summary" ]]; then
        IFS='|' read -r passed failed < "$run/summary" || return 1
    fi
    [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || return 1
    SUITES_PASSED=$((SUITES_PASSED + passed))
    SUITES_FAILED=$((SUITES_FAILED + failed))
    if ((result != 0)); then
        ((failed != 0)) || suite_fail unit-pool
        print_summary
        exit "$result"
    fi
}
