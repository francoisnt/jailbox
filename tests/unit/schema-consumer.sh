#!/bin/bash
# Exercise the public configuration contract from a Python subprocess consumer.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 "$ROOT/tests/lib/check-schema-consumer.py" "$ROOT/src/jailbox" "$(command -v bash)"
