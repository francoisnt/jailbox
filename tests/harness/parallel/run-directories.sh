#!/bin/bash
# Exercise run ownership and multi-gate dispatch without container prerequisites.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tests/lib"
cp "$ROOT/tests/lib/logging.sh" "$tmp/tests/lib/"
# Keep the actual argument parsing, logging entrypoint and gate loop. Other
# harness suites cover prerequisites and the individual gate implementations.
# shellcheck disable=SC2016 # Variables expand when the generated runner executes.
sed -e '/^require_gate_prerequisites() {/,/^}/c\
require_gate_prerequisites() { :; }' \
    -e '/^run_gate() {/,/^}/c\
run_gate() {\
    test_suite_directory "$JAILBOX_DIR" "$1" fixture || exit 1\
    printf "%s\\n" "$1" >> "$JAILBOX_TEST_RUN_DIR/order"\
    printf "output\\n" > "$TEST_SUITE_LOG_DIR/output"\
    [[ ${FAIL_GATE:-} != "$1" ]] || exit 42\
}' "$ROOT/tests/run" > "$tmp/tests/run"

run_count() { find "$tmp/testlog" -mindepth 1 -maxdepth 1 -type d | wc -l; }
for selection in runtime 'runtime matrix' ''; do
    # Intentional splitting supplies the requested gate list.
    # shellcheck disable=SC2086
    bash "$tmp/tests/run" $selection > "$tmp/output"
done
[[ $(run_count) = 3 ]]
single=0 mixed=0 all=0
for run in "$tmp"/testlog/*; do
    [[ ${run##*/} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.[0-9]{3}Z$ ]]
    order=$(paste -sd ' ' "$run/order")
    case "$order" in
        runtime) single=1 ;;
        'runtime matrix') mixed=1 ;;
        'portable runtime matrix editor') all=1 ;;
        *) exit 1 ;;
    esac
    while IFS= read -r gate; do [[ -f "$run/$gate/fixture/output" ]]; done < "$run/order"
done
[[ $single$mixed$all = 111 ]]
result=0
FAIL_GATE=runtime bash "$tmp/tests/run" runtime matrix > "$tmp/output" || result=$?
[[ $result = 42 && $(run_count) = 4 ]]
if bash "$tmp/tests/run" runtime unknown > "$tmp/output" 2>&1; then exit 1; fi
if bash "$tmp/tests/run" matrix matrix > "$tmp/output" 2>&1; then exit 1; fi
[[ $(run_count) = 4 ]]

# A child suite shares its invocation, but a copied repository stays isolated.
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
test_run_directory "$tmp/parent"
parent_run=$JAILBOX_TEST_RUN_DIR
JAILBOX_TEST_GATE=matrix
test_suite_directory "$tmp/parent" runtime wrapper
[[ $TEST_SUITE_LOG_DIR = "$parent_run/matrix/wrapper" ]]
test_suite_directory "$tmp/child" runtime wrapper
[[ $JAILBOX_TEST_RUN_DIR != "$parent_run" && $TEST_SUITE_LOG_DIR = "$tmp/child/testlog/"*/runtime/wrapper ]]
printf 'PASS: dated runs isolate invocations and group single, mixed and all gates\n'
