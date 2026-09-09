#!/bin/bash
# A bind-release race can recover; unrelated errors and lasting conflicts fail.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/integration/runtime-security.sh
source "$ROOT/tests/integration/runtime-security.sh"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
printf 'Port 22231\n' > "$FIXTURE/config"
fail() { printf 'FAIL: %s\n' "$*"; }
sleep() { :; }
podman() {
    local attempts
    attempts=$(cat "$FIXTURE/attempts")
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$FIXTURE/attempts"
    case "$CASE" in
        transient) [[ "$attempts" -le 2 ]] || return 0 ;;
        unrelated) echo 'container storage is unavailable' >&2; return 125 ;;
        other_port) echo 'pasta failed: Failed to bind port 22232 (Address already in use)' >&2; return 125 ;;
    esac
    echo 'pasta failed with exit code 1: Failed to bind port 22231 (Address already in use)' >&2
    return 125
}
for CASE in transient persistent unrelated other_port; do
    echo 0 > "$FIXTURE/attempts"
    status=0
    start_runtime_fixture test-container "$FIXTURE/config" > "$FIXTURE/output" 2>&1 || status=$?
    attempts=$(cat "$FIXTURE/attempts")
    case "$CASE" in
        transient) [[ "$status" = 0 && "$attempts" = 3 ]] ;;
        persistent) [[ "$status" = 1 && "$attempts" = 10 ]] ;;
        *) [[ "$status" = 1 && "$attempts" = 1 ]] ;;
    esac
    if [[ "$status" != 0 ]]; then grep -q 'FAIL: could not restart fixture' "$FIXTURE/output"; fi
    echo "PASS: runtime restart $CASE"
done
