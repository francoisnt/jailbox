#!/bin/bash
# Product and parallel harness suites share a pool; exclusive suites follow.
# shellcheck source=scripts/lib/process-pool.sh
source "$JAILBOX_DIR/scripts/lib/process-pool.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$JAILBOX_DIR/scripts/lib/worker-resources.sh"

# Discovery always owns full portable membership. Dev only filters its default
# subset; explicit additions override exclusions without scheduling duplicates.
portable_suite_catalog() {
    local mode=$1 file name catalog group entries
    shift
    local -A excluded=() discovered=()
    catalog=""
    entries=$(find "$SCRIPT_DIR/harness" -type f -name '*.sh' -print) || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        case "${file%/*}" in
            "$SCRIPT_DIR/harness/parallel"|"$SCRIPT_DIR/harness/exclusive") ;;
            *) printf 'Unclassified harness suite: tests/%s\n' "${file#"$SCRIPT_DIR/"}" >&2; return 1 ;;
        esac
    done <<< "$entries"
    for group in unit harness/parallel harness/exclusive; do
        entries=$(find "$SCRIPT_DIR/$group" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort) || return 1
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            name=${file##*/}
            [[ "$name" =~ ^[a-z0-9-]+\.sh$ ]] || { printf 'Invalid portable suite: %s\n' "$file" >&2; return 1; }
            [[ -z ${discovered[$name]-} ]] || { printf 'Duplicate portable suite name: %s\n' "$name" >&2; return 1; }
            discovered[$name]=true
            catalog+="$group/$name"$'\n'
        done <<< "$entries"
    done
    if [[ "$mode" = dev ]]; then
        while IFS= read -r name; do
            [[ -n "$name" && "$name" != \#* ]] || continue
            [[ "$name" =~ ^[a-z0-9-]+\.sh$ && -n ${discovered[$name]-} && -z ${excluded[$name]-} ]] || {
                printf 'Invalid dev exclusion: %s\n' "$name" >&2; return 1;
            }
            excluded[$name]=true
        done < "$SCRIPT_DIR/lib/dev-exclude.txt" || return 1
        for name in "$@"; do
            [[ "$name" =~ ^[a-z0-9-]+\.sh$ && -n ${discovered[$name]-} ]] || return 1
            unset 'excluded[$name]'
        done
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        name=${file##*/}
        [[ "$name" =~ ^[a-z0-9-]+\.sh$ ]] || return 1
        [[ -n ${excluded[$name]-} ]] || printf '%s\n' "$file"
    done <<< "$catalog"
}

portable_suite_pool() (
    local run=$1 workers=$2 catalog file status=0 passed=0 failed=0 completed=0 total
    local started=$SECONDS last_progress=-15 suite_gate=${GATE:-portable}
    shift 2
    catalog=$(portable_suite_catalog "$suite_gate" "$@") || return 1
    total=0
    while IFS= read -r file; do
        [[ -z "$file" ]] || total=$((total + 1))
    done <<< "$catalog"
    mkdir -p "$run/unit" "$run/harness/parallel" "$run/harness/exclusive" || return 1

    # shellcheck disable=SC2329 # Operation-scoped EXIT cleanup.
    portable_pool_cleanup() {
        local result=$?
        trap - EXIT
        trap '' HUP INT TERM
        process_pool_cancel || result=1
        printf '%s|%s\n' "$passed" "$failed" > "$run/summary" || result=1
        test_progress_complete '%s suites: %s/%s completed · %ss · logs: %s\n' "$suite_gate" "$completed" "$total" "$((SECONDS - started))" "$run"
        exit "$result"
    }
    trap portable_pool_cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP

    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_report() {
        local suite=$1 result=$2 elapsed=$3 name
        printf '%s|%s|%s\n' "$suite" "$result" "$elapsed" >> "$run/timings" || return 1
        if ((result == 0)); then
            passed=$((passed + 1))
            test_log_result PASS "$suite_gate/${suite%.sh}" "$elapsed"
        else
            failed=$((failed + 1))
            test_log_result FAIL "$suite_gate/${suite%.sh}" "$elapsed"
            name=${suite##*/}
            printf 'Rerun: tests/run dev %s\n' "${name%.sh}"
        fi
        if ((result != 0)) || [[ ${GITHUB_ACTIONS:-false} = true ]]; then
            test_log_group "$suite_gate/${suite%.sh}" "$run/$suite.log" || return 1
        fi
        completed=$((completed + 1))
    }
    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_progress() {
        local elapsed=$((SECONDS - started))
        test_progress_due "$last_progress" "$elapsed" || return 0
        last_progress=$elapsed
        printf 'Progress: %s: %s/%s done · %s running · %s failed · %ss\n' "$suite_gate" \
            "$completed" "$total" "${#PROCESS_POOL_LABELS[@]}" "$failed" "$elapsed"
    }
    # shellcheck disable=SC2329 # Process-pool callbacks.
    portable_pool_launch() {
        local suite=$1
        [[ "$PROCESS_POOL_RESULT" = 0 ]] || return 1
        # Nested auto-sized tools must not each claim the host's whole budget.
        JAILBOX_TEST_JOB_LIMIT=1 python3 "$SCRIPT_DIR/lib/run-suite.py" bash "$SCRIPT_DIR/$suite" \
            > "$run/$suite.log" 2>&1 &
        PROCESS_POOL_LAUNCHED_PID=$!
    }
    process_pool_init "$workers" portable_pool_report portable_pool_progress || return 1
    printf '%s: %s shared workers; exclusive harness suites run individually · logs: %s\n' "$suite_gate" "$workers" "$run"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if [[ "$file" = harness/exclusive/* ]]; then
            process_pool_wait || { status=1; break; }
        fi
        process_pool_submit "$file" portable_pool_launch "$file" || { status=1; break; }
        if [[ "$file" = harness/exclusive/* ]]; then
            process_pool_wait || { status=1; break; }
        fi
    done <<< "$catalog"
    process_pool_wait || status=1
    return "$status"
)

run_portable_suites() {
    local run workers result=0 passed=0 failed=0
    workers=$(worker_tool_budget portable) || return 1
    test_suite_directory "$JAILBOX_DIR" "${GATE:-portable}" suites || return 1
    run=$TEST_SUITE_LOG_DIR
    portable_suite_pool "$run" "$workers" "$@" || result=$?
    if [[ -f "$run/summary" ]]; then
        IFS='|' read -r passed failed < "$run/summary" || return 1
    fi
    [[ "$passed" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || return 1
    SUITES_PASSED=$((SUITES_PASSED + passed))
    SUITES_FAILED=$((SUITES_FAILED + failed))
    if ((result != 0)); then
        ((failed != 0)) || suite_fail suite-pool
        print_summary
        exit "$result"
    fi
}
