#!/bin/bash
# A Go command double for checking target selection and publication.
set -euo pipefail
if [[ "$*" = 'env GOVERSION' ]]; then
    printf 'go%s.1\n' "$GO_BUILD_SERIES"
    exit 0
fi
[[ "$1" = build && "$CGO_ENABLED" = 0 && "$GOTOOLCHAIN" = local && "$GOWORK" = off ]]
target="${GOOS}-${GOARCH}"
program=${!#}
printf '%s %s\n' "$target" "$program" >> "$GO_BUILD_TRACE"
if [[ "$program" = ./host/core/cmd/jailbox-core && "$target" = "${GO_BUILD_FAIL_TARGET:-}" ]]; then
    exit 42
fi
while (($#)); do
    if [[ "$1" = -o ]]; then
        printf '%s %s %s\n' "$target" "$program" "$GO_BUILD_MARKER" > "$2"
        chmod 755 "$2"
        exit 0
    fi
    shift
done
exit 1
