#!/bin/bash
# List available dependency updates for this checkout, one per line.
# Copy a line into scripts/apply-updates.sh to prepare a change locally.
# With --check, require current versions and verify VSCodium's build commit.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULES="$ROOT/scripts/lib/dependency_updates.py"

check=false
if [[ $# == 1 && $1 == --check ]]; then
    check=true
elif (($# != 0)); then
    echo 'usage: plan-updates.sh [--check]' >&2
    exit 2
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

if ! bash "$ROOT/scripts/resolve-updates.sh" > "$work/newest"; then
    if [[ "$check" == true ]]; then
        echo 'Could not verify that all dependency pins are current.' >&2
    fi
    exit 1
fi
series=$(bash "$ROOT/scripts/go-series.sh") || exit 1
updates=$(python3 "$RULES" pending --newest "$work/newest" --versions "$ROOT/versions.env" \
    --go-series "$series") || exit 1
if [[ -z "$updates" ]]; then
    if [[ "$check" == true ]]; then
        pin=$(python3 "$RULES" codium-pin "$ROOT/versions.env") || exit 1
        read -r version pinned_commit <<< "$pin"
        if ! commit=$(bash "$ROOT/scripts/resolve-codium-commit.sh" "$version"); then
            printf 'Could not verify the VSCodium build commit for %s.\n' "$version" >&2
            exit 1
        fi
        if [[ "$pinned_commit" != "$commit" ]]; then
            printf 'CODIUM_COMMIT does not match VSCodium %s. To update it, run:\n' "$version" >&2
            printf '  bash scripts/apply-updates.sh CODIUM_VERSION=%s CODIUM_COMMIT=%s\n' "$version" "$commit" >&2
            exit 1
        fi
    fi
    echo 'All dependency pins are current.' >&2
    exit 0
fi
if [[ "$check" == true ]]; then
    printf 'Release requires updated dependency pins. Available updates:\n%s\n' "$updates" >&2
    echo 'Run bash scripts/plan-updates.sh locally for the full update values.' >&2
    exit 1
fi

while IFS= read -r update; do
    if [[ "$update" == CODIUM_VERSION=* ]]; then
        commit=$(bash "$ROOT/scripts/resolve-codium-commit.sh" "${update#*=}") || exit 1
        update=$(python3 "$RULES" complete --update "$update" --codium-commit "$commit") || exit 1
    fi
    printf '%s\n' "$update" >> "$work/updates"
done <<< "$updates"
cat "$work/updates"
