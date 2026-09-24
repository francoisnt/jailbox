#!/usr/bin/env bash
# Run shellcheck on all shell scripts in the repository.
#
# Usage: scripts/lint.sh [--format <fmt>]
# Flags are forwarded to shellcheck.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
# The gate already owns rendering; direct invocations use that same renderer.
# shellcheck source=tests/lib/logging.sh
source "$SCRIPT_DIR/../tests/lib/logging.sh"
if [[ -z ${JAILBOX_TEST_LOG_SCRIPT:-} ]]; then
    test_log_entrypoint "$SCRIPT_DIR/lint.sh" "$@"
fi

# Standalone bash scripts. Discover repository tooling and tests so adding a
# new suite cannot silently leave it outside ShellCheck coverage.
bash_scripts=(src/install.sh tests/run)
files=$(find scripts tests -type f -name '*.sh' ! -path 'tests/run' -print | LC_ALL=C sort)
while IFS= read -r script; do
    bash_scripts+=("$script")
done <<< "$files"

# Modules are checked in entrypoint context above. Also discover every module,
# including new unreferenced files; standalone module state/callbacks are shared.
host_scripts=(src/public-api.sh)
files=$(find src/host -type f -name '*.sh' -print | LC_ALL=C sort)
while IFS= read -r script; do
    [[ -z "$script" ]] || host_scripts+=("$script")
done <<< "$files"

# shellcheck source=scripts/lib/container-shells.sh
source "$SCRIPT_DIR/lib/container-shells.sh"
collect_container_shells src

# shellcheck source=scripts/lib/process-pool.sh
source "$SCRIPT_DIR/lib/process-pool.sh"
# shellcheck source=scripts/lib/worker-resources.sh
source "$SCRIPT_DIR/lib/worker-resources.sh"
lint_workers=$(worker_tool_budget lint)
mkdir -p testlog
lint_output=$(mktemp -d "$PWD/testlog/shellcheck.XXXXXXXX")
lint_started=$SECONDS
lint_completed=0
lint_last_progress=-15
lint_total=$((2 + (${#bash_scripts[@]} + 7) / 8))
[[ -z ${container_bash[*]-} ]] || lint_total=$((lint_total + 1))
[[ -z ${container_sh[*]-} ]] || lint_total=$((lint_total + 1))
lint_finished=false
lint_batch=0
lint_labels=()
# shellcheck disable=SC2329 # Invoked by the EXIT trap after entrypoint re-exec.
lint_cleanup() {
    local status=$?
    trap - EXIT
    trap '' HUP INT TERM
    process_pool_cancel 7 || status=1
    if [[ "$lint_finished" = false ]]; then
        printf 'ShellCheck interrupted · %ss · logs: %s\n' "$((SECONDS - lint_started))" "$lint_output"
    fi
    exit "$status"
}
trap lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck disable=SC2329 # Shared process-pool completion callback.
lint_report() {
    local batch=$1 status=$2 elapsed=$3 result=passed
    ((status == 0)) || result="FAILED ($status)"
    printf '%s: %s, %ss (output: %s)\n' "${lint_labels[batch]}" "$result" "$elapsed" "$batch" >> "$lint_output/timings.log" || return 1
    if ((status != 0)) || [[ -s "$lint_output/$batch" ]]; then
        printf 'ShellCheck diagnostics: %s\n' "${lint_labels[batch]}" || return 1
        test_log_group "ShellCheck: ${lint_labels[batch]}" "$lint_output/$batch" || return 1
    fi
    lint_completed=$((lint_completed + 1))
}
# shellcheck disable=SC2329 # Shared process-pool progress callback.
lint_progress() {
    local elapsed=$((SECONDS - lint_started)) interval=15
    [[ ${JAILBOX_TEST_PROGRESS_TERMINAL:-false} != true ]] || interval=1
    ((elapsed - lint_last_progress >= interval)) || return 0
    lint_last_progress=$elapsed
    printf 'Progress: ShellCheck: %s/%s batches complete · %s running · %ss elapsed\n' \
        "$lint_completed" "$lint_total" "${#PROCESS_POOL_LABELS[@]}" "$elapsed"
}
# shellcheck disable=SC2329 # Shared process-pool launch callback.
lint_launch() {
    local batch=$1
    shift
    # The shared supervisor timestamps output and owns the command's process
    # group, including cancellation; allow its five-second cleanup to finish.
    python3 "$SCRIPT_DIR/../tests/lib/run-suite.py" "$@" > "$lint_output/$batch" 2>&1 &
    PROCESS_POOL_LAUNCHED_PID=$!
}
lint_job() {
    lint_labels[lint_batch]=$1
    shift
    process_pool_submit "$lint_batch" lint_launch "$lint_batch" "$@" || return 1
    lint_batch=$((lint_batch + 1))
}
process_pool_init "$lint_workers" lint_report lint_progress
printf 'workers=%s\n' "$lint_workers" > "$lint_output/resources.log"
# Preserve full source-context analysis at the public entrypoint.
lint_job 'jailbox (+ sourced host modules)' shellcheck --check-sourced --external-sources --shell=bash "$@" src/jailbox
# Small batches let the second worker keep going while an expensive source
# graph is checked. Limit concurrency, not the checks each file receives.
for ((offset=0; offset<${#bash_scripts[@]}; offset+=8)); do
    lint_job "scripts/tests batch $((offset / 8 + 1))" shellcheck --external-sources --shell=bash "$@" "${bash_scripts[@]:offset:8}"
done
lint_job 'host modules' shellcheck --external-sources --shell=bash --exclude=SC2034,SC2329 "$@" "${host_scripts[@]}"
if [[ -n ${container_bash[*]-} ]]; then
    lint_job 'container Bash scripts' shellcheck --shell=bash "$@" "${container_bash[@]}"
fi
if [[ -n ${container_sh[*]-} ]]; then
    lint_job 'container POSIX sh scripts' shellcheck --shell=sh "$@" "${container_sh[@]}"
fi
lint_result=0
process_pool_wait || lint_result=1
lint_finished=true
if ((lint_result == 0)); then lint_summary=passed; else lint_summary=failed; fi
printf 'ShellCheck %s · %ss · logs: %s\n' "$lint_summary" "$((SECONDS - lint_started))" "$lint_output"
exit "$lint_result"
