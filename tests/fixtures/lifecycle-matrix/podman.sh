#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$LIFECYCLE_BACKEND_LOG"
