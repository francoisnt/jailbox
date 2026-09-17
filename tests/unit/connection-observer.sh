#!/bin/bash
# Verify the real matrix connection observer rejects partial/misleading streams
# and treats attempted writes as failures even when the command itself refused.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
GENERATION='/state with spaces/ssh-generation'
PREFIX=jailbox-project-012345abcdef
HASH=012345abcdef
JAILBOX_CONFIG_EGRESS_ALLOW_0=''
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_die() { fail "$@"; }
cli() {
    [[ "$1" = connection-info && "$LIFECYCLE_READONLY" = true ]] || fail 'observer did not require read-only connection-info'
    cat "$tmp/reply"
    printf '%s' "$diagnostic" >&2
    return "$reply_status"
}
printf 'ssh_config\t%s\0ssh_host\t%s\0remote_path\t%s\0project_id\t%s\0proxy_url\t\0' \
    "$GENERATION/ssh_config" "$PREFIX" /home/jailbox/project "$HASH" > "$tmp/golden"
cp "$tmp/golden" "$tmp/reply"
reply_status=0 diagnostic=''
observe_connection allow "$tmp/observation"
reject() {
    if (observe_connection "$1" "$tmp/observation") >/dev/null 2>&1; then fail 'observer accepted invalid attachment'; fi
}
reply_status=125 diagnostic=failed
reject allow
reject refuse # Plausible records accompanying failure are invalid.
: > "$tmp/reply"
observe_connection refuse "$tmp/observation"
diagnostic='read-only observer attempted mutation'
reject refuse
diagnostic=''
reject refuse
reply_status=0
reject allow
# Missing, duplicate, unterminated, and malformed records all fail the producer
# golden oracle. Future consumer extension/framing tests are owned by frontend.
for bad in 'ssh_config' 'ssh_config\t/tmp/config' 'ssh_config\t/tmp/config\0' 'BadName\tvalue\0' 'proxy_url\t\0proxy_url\t\0'; do
    printf '%b' "$bad" > "$tmp/reply"
    reject allow
done
printf 'PASS: connection observer enforces framing, exit success, and non-mutation\n'
