#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/tree/tests/lib/sandbox" "$fixture/tree/tests/fixtures/shell" "$fixture/tree/src" "$fixture/bin" "$fixture/project"
cp "$ROOT/tests/lib/shell-connection.sh" "$fixture/tree/tests/lib/"
cp "$ROOT/tests/lib/sandbox/shell-profile.sh" "$fixture/tree/tests/lib/sandbox/"
cp "$ROOT/tests/fixtures/shell/login-profile.sh" "$fixture/tree/tests/fixtures/shell/"
cp "$ROOT/tests/fixtures/shell/runtime-tools.sh" "$fixture/tree/src/jailbox"
chmod 755 "$fixture/tree/src/jailbox"
for tool in python3 podman; do ln -s "$fixture/tree/src/jailbox" "$fixture/bin/$tool"; done
export TERMINAL_TEST_TRACE="$fixture/trace"
for scope in full frontend; do
    : > "$TERMINAL_TEST_TRACE"
    PATH="$fixture/bin:$PATH" bash "$ROOT/tests/lib/shell-runtime.sh" \
        "$fixture/tree" "$fixture/project" sandbox "$fixture/output" "$scope"
    grep -q -- '--exercise.*--proxy http://10.0.0.2:8888' "$TERMINAL_TEST_TRACE"
    grep -q 'bash -s -- restore' "$TERMINAL_TEST_TRACE"
    if [[ "$scope" = frontend ]]; then
        [[ $(grep -c 'shell-terminal.py' "$TERMINAL_TEST_TRACE") = 1 ]]
        grep -q -- '--startup-only' "$TERMINAL_TEST_TRACE"
    else
        [[ $(grep -c 'shell-terminal.py' "$TERMINAL_TEST_TRACE") = 2 ]]
        if grep -q -- '--startup-only' "$TERMINAL_TEST_TRACE"; then exit 1; fi
    fi
    result=0
    PATH="$fixture/bin:$PATH" TERMINAL_TEST_STATUS=7 bash "$ROOT/tests/lib/shell-runtime.sh" \
        "$fixture/tree" "$fixture/project" sandbox "$fixture/output" "$scope" || result=$?
    [[ "$result" = 7 && $(tail -1 "$TERMINAL_TEST_TRACE") = *'bash -s -- restore' ]]
done
printf 'PASS: frontend terminal scope preserves profile coverage, full core scope, and cleanup on failure\n'
