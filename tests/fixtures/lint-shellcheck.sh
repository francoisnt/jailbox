#!/bin/bash
# Record the lint driver's discovered inputs and dialect/source-analysis flags.
set -euo pipefail
printf '%s\n' "$*" >> "$LINT_INVOCATIONS"
