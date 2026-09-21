#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R "$ROOT/host" "$tmp/host"
python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp"
# shellcheck disable=SC2016 # Literal shell references are boundary fixtures.
for violation in 'configure_network' 'configure_network() { :; }' 'DEV_IMAGE=bad' 'declare -g DEV_IMAGE=unexpected' 'declare -g "DEV_IMAGE=unexpected"' 'printf -v SSH_CONFIG %s /tmp/private' 'printf -v "SSH_CONFIG" %s /tmp/private' 'bad() { NETWORK_STATE[proxy_url]=unexpected; }' 'printf "%s" "$SSH_CONFIG"' 'cat "$HOME/.local/state/jailbox/projects/id/ssh-generation/ssh_config"' 'podman ps' '"podman" ps' 'if podman ps; then :; fi' 'env podman ps' 'source host/core/common.sh'; do
    printf '%s\n' "$violation" > "$tmp/host/frontend/violation.sh"
    if python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp" > "$tmp/error" 2>&1; then
        echo "Accepted boundary violation: $violation" >&2
        exit 1
    fi
    grep -q 'private core' "$tmp/error"
done
printf '%s\n' "printf '%s' 'DEV_IMAGE=literal' 'SSH_CONFIG' 'NETWORK_STATE[key]=literal'" > "$tmp/host/frontend/violation.sh"
python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp"
printf '%s\n' 'printf "%s\n" "Install the command podman before launching"' > "$tmp/host/frontend/violation.sh"
python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp"
for declaration in 'declare -A FUTURE_PRIVATE' 'declare -r -A FUTURE_PRIVATE=()'; do
    printf '%s\n' "$declaration" > "$tmp/host/core/future.sh"
    printf 'FUTURE_PRIVATE[key]=bad\n' > "$tmp/host/frontend/violation.sh"
    if python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp" > "$tmp/error" 2>&1; then
        echo "Missed private declaration: $declaration" >&2
        exit 1
    fi
    grep -q 'private core reference: FUTURE_PRIVATE' "$tmp/error"
done
rm "$tmp/host/core/future.sh" "$tmp/host/frontend/violation.sh"
for declaration in CONFIG_SCALAR_KEYS CONFIG_ARRAY_KEYS; do
    sed "s/^$declaration=/RENAMED=/" "$ROOT/host/public-api.sh" > "$tmp/host/public-api.sh"
    if python3 "$ROOT/scripts/check-frontend-boundary.py" "$tmp" > "$tmp/error" 2>&1; then
        echo "Accepted missing declaration: $declaration" >&2
        exit 1
    fi
    grep -q "missing public declaration: $declaration" "$tmp/error"
    if grep -q Traceback "$tmp/error"; then exit 1; fi
done
printf 'PASS: boundary rejects private helpers, globals, paths, sources, and engine calls\n'
