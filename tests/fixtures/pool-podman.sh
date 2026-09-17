#!/bin/bash
set -euo pipefail
[[ "$*" != 'image exists jailbox-test-debian' ]] || exit 0
[[ ${2:-} != exists ]] || exit 1
echo 'Unexpected engine mutation during coordinator test' >&2
exit 97
