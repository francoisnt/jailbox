#!/bin/bash
# CLI syntax and frontend-only commands must not initialize machine modules.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tool/host" "$tmp/project"
cp "$ROOT/src/jailbox" "$tmp/tool/jailbox"
cp "$ROOT/src/public-api.sh" "$tmp/tool/"
cp "$ROOT/src/host/"{api-support,cli}.sh "$tmp/tool/host/"
mkdir "$tmp/tool/host/core"
cp "$ROOT/src/host/core/schema.sh" "$tmp/tool/host/core/"
cp -R "$ROOT/src/host/frontend" "$tmp/tool/host/"
cli() { (cd "$tmp/project" && "$tmp/tool/jailbox" "$@"); }
cli --help > "$tmp/help"
grep -q -- --no-editor "$tmp/help"
cli config-schema > "$tmp/schema"
if grep -q EDITOR "$tmp/schema"; then exit 1; fi
cli init
[[ -f "$tmp/project/jailbox.conf" ]]
# Lookup inputs are data, including shell-looking text and array syntax.
# shellcheck disable=SC2016 # Shell syntax is deliberately literal input.
for command in '$(touch forbidden)' 'x[$(touch forbidden)]' --unknown; do
    status=0
    cli "$command" > "$tmp/out" 2> "$tmp/error" || status=$?
    [[ "$status" = 2 && ! -e "$tmp/project/forbidden" ]]
done
for args in repeated misplaced missing unexpected; do
    status=0
    case "$args" in
        repeated) cli --config one --config two ;;
        misplaced) cli --no-editor --config one ;;
        missing) cli --config ;;
        unexpected) cli --no-editor extra ;;
    esac > "$tmp/out" 2> "$tmp/error" || status=$?
    [[ "$status" = 2 ]]
done
# Every declared command except file-driven launch/validation rejects --config
# before attempting to load core (which is deliberately absent in this fixture).
# shellcheck source=src/public-api.sh
source "$ROOT/src/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$ROOT/src/host/api-support.sh"
initialize_public_api_lookups
for command in "${CLI_FLAGS_WITHOUT_VALUES[@]}"; do
    case "$command" in --no-editor|validate) continue ;; esac
    status=0
    cli --config selected.conf "$command" > "$tmp/out" 2> "$tmp/error" || status=$?
    [[ "$status" = 2 ]]
    grep -Fq -- "--config cannot be used with $command" "$tmp/error"
done
# The retired environment override must not be validated by local init/help.
JAILBOX_EDITOR=invalid EDITOR=invalid cli --help > /dev/null
printf 'PASS: frontend-only loading, declared help/schema, and strict CLI syntax\n'
