#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/tests/lib/lifecycle-matrix.sh"
source "$root/tests/lib/lifecycle-jobs.sh"
source "$root/tests/lib/resource-ledger.sh"
run="$1"; log="$2"
ledger_begin_run mock-worker
printf '%s\n' "$LEDGER_FILE" > "$log/ledger"
printf '%s\n' "$3" > "$log/fixture"
: > "$log/cases"
: > "$log/expected-faults"
case ${POOL_TEST_MODE:-normal} in
    fail) exit 42 ;;
    wait)
        # Ownership must be registered before any worker work begins.
        grep -Eq "^owner $$ " "$LIFECYCLE_POOL_LEDGER"
        trap 'printf stopped > "$log/stopped"' EXIT
        trap 'exit 143' TERM
        printf '%s\n' "$$" > "$run/mock-started-$$"
        while :; do sleep 0.05; done
        ;;
esac
complete_job() {
    local kind="$1" key
    shift
    case "$kind" in
        row)
            for key in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
                local selected=0
                lifecycle_case_selected "$run" "$1.$key" || selected=$?
                case "$selected" in
                    0) printf '%s.%s\n' "$1" "$key" ;;
                    1) ;;
                    *) return 1 ;;
                esac
            done ;;
        fault)
            printf 'trace.%s.%s\n' "$1" "$2"
            printf 'mkdir /fixture/state\n' > "$log/trace"
            lifecycle_fault_cases "$log/trace" "$1" "$2" | tee -a "$log/expected-faults"
            ;;
        special)
            case "$1" in
                resume) key='^failed-resume\.' ;;
                removal) key='^failed-new-container-cleanup$' ;;
                dependency) key='^failed-create\.' ;;
                inspection) key='^home-inspection\.' ;;
            esac
            lifecycle_fixed_cases | grep -E "$key"
            ;;
    esac | sed 's/$/|0/' >> "$log/cases"
}
lifecycle_run_queue "$run" complete_job </dev/null
