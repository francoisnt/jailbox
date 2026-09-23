#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 "$ROOT/tests/lib/check-stage-pool.py" "$ROOT/tests/fixtures/stage-pool/runner.sh"
