#!/bin/bash
# Health variants must all execute, actually damage their target property, and
# retain their recovery assertions even when a child consumes standard input.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
FIXTURE=$tmp LOG=$tmp GENERATION="$tmp/generation" PREFIX=fixture CASE_KEY=running.up
mkdir "$GENERATION"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_die() { fail "$@"; }
construct() {
    printf '%s\n' "$1" >> "$tmp/constructed"
    printf receipt > "$GENERATION/container-id"
    cat > /dev/null # Like a child SSH invocation, must not drain the catalog.
}
podman() {
    case "$1" in
        container)
            printf '%s\n' podman run --read-only --cap-drop=ALL --security-opt=no-new-privileges \
                -v "$tmp/project/attachment-policy:/home/jailbox/project/attachment-policy:Z,ro" fixture-image
            ;;
        rm)
            if [[ "$remove_receipt" = true ]]; then
                rm "$GENERATION/container-id"
            fi
            ;;
        run)
            [[ ! -e "$GENERATION/container-id" ]] || fail 'old container receipt survived removal'
            printf receipt > "$GENERATION/container-id"
            printf '%s\n' "$*" >> "$tmp/replays"
            ;;
        kill) printf '%s\n' "$*" >> "$tmp/signals" ;;
        *) fail 'unexpected fixture engine command' ;;
    esac
}
matrix_observe() {
    printf '%s:%s\n' "$1" "$3" >> "$tmp/observed"
    printf 'jailbox stop\n' > "$LOG/$CASE_KEY.$1.connection.stderr"
}
expect_success() { printf '%s\n' "$1" >> "$tmp/recoveries"; }
assert_marker() { [[ "$1" = keep ]] || fail 'health recovery lost persistent home'; }
for remove_receipt in false true; do
    rm -f "$tmp/constructed" "$tmp/observed" "$tmp/recoveries" "$tmp/replays" "$tmp/signals"
    observe_health_variants < /dev/null
    [[ $(wc -l < "$tmp/constructed") = 8 && $(wc -l < "$tmp/observed") = 15 ]] || fail 'health variants or recovery observations were skipped'
    [[ $(wc -l < "$tmp/recoveries") = 14 ]] || fail 'health recovery not executed'
    [[ $(wc -l < "$tmp/replays") = 5 && $(wc -l < "$tmp/signals") = 2 ]] || fail 'health damage not applied'
    grep -q -- '--read-only=false' "$tmp/replays"
    grep -q -- '--cap-drop=CHOWN' "$tmp/replays"
    grep -q -- 'attachment-policy:Z,rw' "$tmp/replays"
    grep -q -- '/run/podman/podman.sock:ro,Z' "$tmp/replays"
    [[ $(grep -c -- '--security-opt=no-new-privileges' "$tmp/replays") = 4 ]] || fail 'privileges variant did not remove no-new-privileges'
    grep -Fxq 'health-upstream:allow' "$tmp/observed"
done
printf 'PASS: all eight health variants alter their target and execute their assertions\n'
