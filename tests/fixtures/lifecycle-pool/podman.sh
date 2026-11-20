#!/bin/bash
set -euo pipefail
[[ "$*" != 'image exists jailbox-test-debian' ]] || exit 0
[[ ${2:-} != exists ]] || exit 1
# Host networks: POOL_TEST_HOST_OCTETS lists occupied 10.240.N.0/24 subnets.
if [[ "$*" = 'network ls --format {{.Name}}' ]]; then printf 'podman\n'; exit 0; fi
if [[ "${1:-} ${2:-}" = 'network inspect' ]]; then
    for octet in ${POOL_TEST_HOST_OCTETS-}; do printf '[{"subnets": [{"subnet": "10.240.%s.0/24"}]}]\n' "$octet"; done
    exit 0
fi
echo 'Unexpected engine mutation during coordinator test' >&2
exit 97
