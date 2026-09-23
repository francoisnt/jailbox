#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/worker-resources.sh
source "$ROOT/scripts/lib/worker-resources.sh"
unset JAILBOX_TEST_JOB_LIMIT
[[ $(worker_budget 8 8388608 1 1572864 524288 16) = 5 ]]
[[ $(worker_budget 2 8388608 1 1572864 524288 16) = 2 ]]
[[ $(worker_budget 64 67108864 1 262144 524288 16) = 16 ]]
[[ $(worker_budget 8 0 1 262144 524288 16) = 1 ]]
[[ $(worker_budget 8 524287 1 262144 524288 16) = 1 ]]
if worker_budget bad 0 1 1 0 16; then exit 1; fi
worker_host_resources() { printf '8|8388608\n'; }
[[ $(worker_tool_budget lint) = 5 ]]
[[ $(worker_tool_budget portable) = 8 ]]
[[ $(worker_tool_budget runtime) = 3 ]]
[[ $(worker_tool_budget editor) = 1 ]]
[[ $(JAILBOX_TEST_JOB_LIMIT=1 worker_tool_budget lint) = 1 ]]
[[ $(JAILBOX_TEST_JOB_LIMIT=3 worker_tool_budget portable) = 3 ]]
if JAILBOX_TEST_JOB_LIMIT=bad worker_tool_budget lint; then exit 1; fi
memory=$(worker_macos_memory <<'VM'
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100.
Pages active:                             999.
Pages inactive:                           200.
Pages speculative:                         10.
VM
)
[[ "$memory" = 4960 ]]
[[ $(worker_macos_memory <<< 'unknown') = 0 ]]
printf 'PASS: workload budgets, CPU/memory bounds, nesting limit, and macOS page accounting\n'
