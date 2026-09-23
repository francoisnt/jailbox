#!/bin/bash
# Real CLI + SSH terminal checks on an existing headless fixture.
set -euo pipefail
ROOT="$1" PROJECT="$2" CONTAINER="$3" OUTPUT="$4"
# shellcheck source=tests/lib/shell-connection.sh
source "$ROOT/tests/lib/shell-connection.sh"
scope=${5:-full}
exercise_args=()
case "$scope" in
    full) ;;
    frontend) exercise_args+=(--startup-only) ;;
    *) printf 'Invalid shell test scope: %s\n' "$scope" >&2; exit 1 ;;
esac
profile_installed=false
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$profile_installed" = true ]]; then
        podman exec -i "$CONTAINER" bash -s -- restore < "$ROOT/tests/lib/sandbox/shell-profile.sh" || result=1
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
proxy=$(shell_connection_proxy "$PROJECT" "$ROOT/src/jailbox" "$OUTPUT.connection-info") || exit 1
if [[ "$scope" = full ]]; then
    python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$PROJECT" --output "$OUTPUT.basic" -- "$ROOT/src/jailbox" shell
fi
podman exec -i "$CONTAINER" bash -s -- install < "$ROOT/tests/lib/sandbox/shell-profile.sh"
profile_installed=true
# shellcheck disable=SC2016 # HOME belongs to the sandbox.
podman exec -i "$CONTAINER" sh -c 'cat > "$HOME/.bash_profile"' < "$ROOT/tests/fixtures/shell/login-profile.sh"
python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$PROJECT" --output "$OUTPUT" --exercise "${exercise_args[@]}" --proxy "$proxy" -- "$ROOT/src/jailbox" shell
if [[ "$scope" = full ]]; then
    printf 'PASS: real login startup, cwd/proxy customization, resize, signals, restoration, and status\n'
else
    printf 'PASS: frontend policy preserves login environment and customization\n'
fi
