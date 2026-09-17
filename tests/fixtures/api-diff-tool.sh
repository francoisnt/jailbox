#!/bin/bash
if [ ! -e "$FAULT_MARKER" ]; then
    : > "$FAULT_MARKER"
    printf '%s' "$FAULT_OUTPUT"
    exit 42
fi
exec "$REAL_TOOL" "$@"
