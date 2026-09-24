#!/bin/bash
# Selection and strict image/container identity framing, without an engine.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
printf 'root:x:0:0:root:/root:/bin/sh\nnode:x:1000:1000::/home/node:/bin/sh\n' > "$fixture/passwd"
printf 'root:x:0:\nnode:x:1000:\noccupied:x:1001:\n' > "$fixture/group"
select_id() {
    awk -v preferred="$1" -f "$ROOT/src/container/select-user-id.awk" "$fixture/passwd" "$fixture/group"
}
[[ $(select_id 1000) = 1002 && $(select_id 1234) = 1234 && $(select_id 0) = 1002 ]]
# shellcheck disable=SC2016 # Deliberately untrusted literal input.
[[ $(select_id 999999) = 1002 && $(select_id '$(false)') = 1002 ]]
awk 'BEGIN { for (i=1000;i<=60000;i++) print "user" i ":x:" i ":" }' > "$fixture/group"
if select_id 1000; then fail 'exhausted IDs accepted'; fi
printf 'PASS: unused user/group selection, preferred ID, root refusal and exhaustion\n'

PROJECT_DEV_IMAGE=test-dev JAILBOX_IMAGE=test-wrapper MY_UID=1000
probe_status=0
probe_output=$'1002\n1002\n'
# shellcheck disable=SC2329 # Called by production build helper.
podman() {
    case "$1 $2" in
        'image exists'|'build -t') return 0 ;;
        'image inspect') printf 'immutable-image\n' ;;
        'run --rm')
            [[ "$*" = *'--network=none'* && "$*" = *'--read-only'* && "$*" = *'--entrypoint /bin/sh'* ]] || return 99
            printf '%s' "$probe_output"
            return "$probe_status" ;;
        *) return 99 ;;
    esac
}
build_jailbox_image > "$fixture/output"
[[ "$MANAGED_ID" = 1002 ]]
for probe_output in $'1002\n1002' $'1002\n1002\n\n' '' $'0\n0' $'01002\n01002' $'1002\n1003' $'60001\n60001' $'1002\n1002\nnoise'; do
    if (build_jailbox_image) > "$fixture/output" 2>&1; then fail 'malformed image identity accepted'; fi
done
probe_output=$'1002\n1002\n'
probe_status=42
if (build_jailbox_image) > "$fixture/output" 2>&1; then fail 'failed image probe accepted plausible identity'; fi
printf 'PASS: image identity probe rejects malformed and failed results\n'

CONTAINER_NAME=test-container
container_identity='1002:1002|private|0:1:1002,1002:0:1,1003:1003:64534,|0:1:1002,1002:0:1,1003:1003:64534,'
probe_status=0
# shellcheck disable=SC2329 # Called by production validator.
podman() { printf '%s\n' "$container_identity"; return "$probe_status"; }
validate_development_identity
for container_identity in '1002:1002|private|0:0:65536,|0:0:65536,' '0:0|private|0:0:1,|0:0:1,' \
    '1002:1003|private|1002:0:1,|1003:0:1,' '1002:1002|host|1002:0:1,|1002:0:1,' \
    '1002:1002|private|1002:0:1,|1002:1:1,'; do
    if (validate_development_identity) > "$fixture/output" 2>&1; then fail 'incompatible runtime mapping accepted'; fi
done
container_identity='1002:1002|private|1002:0:1,|1002:0:1,'
probe_status=42
if (validate_development_identity) > "$fixture/output" 2>&1; then fail 'failed runtime inspection accepted'; fi
printf 'PASS: runtime mapping requires non-root managed UID/GID mapped to host user/group\n'
