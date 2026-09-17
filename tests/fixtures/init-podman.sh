#!/bin/bash
if [ "$1 $2" = "container exists" ]; then
    [ "${FAKE_CONTAINER_NAME:-}" = "$3" ]
elif [ "$1 $2" = "container inspect" ]; then
    printf '%s\n' "${FAKE_CONTAINER_LABELS:-}"
else
    exit 1
fi
