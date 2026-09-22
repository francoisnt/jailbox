#!/bin/bash
# Production resource observations have independent fixture expectations.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR=$ROOT/src
# shellcheck source=src/public-api.sh
source "$SCRIPT_DIR/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$SCRIPT_DIR/host/api-support.sh"
initialize_public_api_lookups
# Loading definitions must not inspect or mutate resources.
# shellcheck disable=SC2329 # Guard against effects while sourcing definitions.
podman() { printf 'unexpected engine call during loading\n' >&2; exit 99; }
# shellcheck source=src/host/core/entry.sh
source "$SCRIPT_DIR/host/core/entry.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reply='' producer_status=0
podman() {
    case "$1:$2" in
        container:inspect|volume:inspect) ;;
        *) fail 'detector attempted a mutation or unexpected observation' ;;
    esac
    printf '%s' "$reply"
    return "$producer_status"
}
expect() {
    local expected="$1" actual
    shift
    actual=$("$@") || fail 'observation failed'
    [[ "$actual" = "$expected" ]] || fail "expected $expected, got $actual"
}
reject() {
    if ("$@") > "$tmp/out" 2> "$tmp/err"; then fail 'accepted invalid observation'; fi
    [[ ! -s "$tmp/out" && -s "$tmp/err" ]] || fail 'failure published a classification or lost its reason'
}
# Inventory distinguishes health from running state; it needs no policy or SSH.
reply=$'true\n'
expect running inspect_container_running fixture
reply=$'false\n'
expect stopped inspect_container_running fixture
for reply in '' true $'true\n\n' $'false\nnoise\n' $'unknown\n'; do
    reject inspect_container_running fixture
done
reply=$'true\n' producer_status=125
reject inspect_container_running fixture
producer_status=0
# The lifecycle detector preserves engine states; unsupported states refuse.
OBSERVED_RESOURCES=(container:fixture)
refuse_sandbox() { printf 'refused: %s\n' "$*" >&2; return 1; }
for state in running exited stopped created configured; do
    reply="$state"
    expect "$state" inspect_container_lifecycle_state fixture
done
reply=paused
reject inspect_container_lifecycle_state fixture
reply=running producer_status=125
reject inspect_container_lifecycle_state fixture
producer_status=0
OBSERVED_RESOURCES=()
expect absent inspect_container_lifecycle_state fixture
# Stored home policy is independent of requested policy. Unknown metadata is
# corrupt, whereas failed observation refuses even with plausible stdout.
VOLUME_NAME=fixture-home
for policy in false true corrupt; do
    reply="$policy"
    expect "$policy" home_retention_policy
done
reply=''
expect false home_retention_policy
reply=unexpected
reject home_retention_policy
reply=false producer_status=125
reject home_retention_policy
# Negative control: a detector returning the wrong known state must fail the
# independently specified expectation, not redefine the expected result.
if (
    # shellcheck disable=SC2329 # Invoked through expect for the negative control.
    inspect_container_running() { printf 'stopped\n'; }
    expect running inspect_container_running fixture
) > "$tmp/negative" 2>&1; then fail 'wrong classification escaped the oracle'; fi
grep -Fq 'expected running, got stopped' "$tmp/negative"
printf 'PASS: independent resource states, observation errors, conditional calls, and negative control\n'
