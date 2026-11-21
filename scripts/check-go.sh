#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../src"
export CGO_ENABLED=0 GOTOOLCHAIN=local GOWORK=off
unformatted=$(gofmt -l .)
if [[ -n "$unformatted" ]]; then
    printf 'Run gofmt on these files:\n' >&2
    while IFS= read -r path; do printf '  src/%s\n' "$path" >&2; done <<< "$unformatted"
    exit 1
fi
go vet -mod=readonly ./...
