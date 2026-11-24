#!/bin/bash
# Apply dependency updates to this checkout and regenerate the derived files.
#
# Usage: scripts/apply-updates.sh UPDATE...
#   Each UPDATE is one or more KEY=VALUE pairs, for example
#   BASE_IMAGE_DEBIAN=debian:13 or "CODIUM_VERSION=1.2.3 CODIUM_COMMIT=<sha>".
#   scripts/lib/dependency_updates.py defines the keys and value formats.
#
# The pin files and generated files must be tracked, with no staged or
# unstaged changes, so a failure can restore them from Git without touching
# anyone's edits. Values are data: they are validated, never evaluated.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
generate() { bash "$ROOT/scripts/gen-tested-matrix.sh" "$@"; }

if (($# == 0)); then
    printf 'usage: %s UPDATE...\n' "${0##*/}" >&2
    exit 2
fi
pairs=$(python3 "$ROOT/scripts/lib/dependency_updates.py" parse "$*") || exit 2

outputs=$(generate --outputs) || exit 1
mapfile -t files <<< "versions.env"$'\n'"src/go.mod"$'\n'"Containerfile"$'\n'"$outputs"
if ! git -C "$ROOT" ls-files --error-unmatch -- "${files[@]}" > /dev/null; then
    printf 'Error: %s must all be tracked by Git.\n' "${files[*]}" >&2
    exit 1
fi
# Check the index and the worktree separately: a staged edit can hide behind
# a worktree copy that matches HEAD.
if ! git -C "$ROOT" diff --quiet --cached -- "${files[@]}" || ! git -C "$ROOT" diff --quiet -- "${files[@]}"; then
    printf 'Error: commit or stash your staged or unstaged changes to %s first.\n' "${files[*]}" >&2
    exit 1
fi

# Print FILE with KEY's quoted value replaced, keeping any trailing comment.
set_pin() {
    local file=$1 key=$2 value=$3
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 {
            rest = substr($0, length(key) + 2)
            sub(/^"[^"]*"/, "", rest)
            print key "=\"" value "\"" rest
            matches++
            next
        }
        { print }
        END { if (matches != 1) exit 1 }
    ' "$file"
}

# Print go.mod with the go directive naming SERIES. Drop a toolchain line
# that names an older series, as Go does when the line adds nothing: without
# it the go directive decides. Preserve Go's other toolchain settings.
set_go_series() {
    local series=$1
    awk -v series="$series" '
        BEGIN { split(series, parts, "."); wanted = parts[2] + 0 }
        !done && $1 == "go" { print "go " series; done = 1; next }
        $1 == "toolchain" && $2 ~ /^go1\.(0|[1-9][0-9]*)([^0-9]|$)/ {
            minor = substr($2, 5)
            sub(/[^0-9].*$/, "", minor)
            if (minor + 0 < wanted) next
        }
        { print }
        END { if (!done) exit 1 }
    ' "$ROOT/src/go.mod"
}

set_go_image() {
    local series=$1
    awk -v series="$series" '
        {
            count = gsub(/golang:[0-9]+[.][0-9]+-trixie/, "golang:" series "-trixie")
            matches += count
            print
        }
        END { if (matches != 1) exit 1 }
    ' "$ROOT/Containerfile"
}

apply_all() {
    local key value pins gomod image
    pins=$(cat "$ROOT/versions.env") || return 1
    gomod=$(cat "$ROOT/src/go.mod") || return 1
    image=$(cat "$ROOT/Containerfile") || return 1
    while IFS=$'\t' read -r key value; do
        if [[ "$key" == GO_SERIES ]]; then
            gomod=$(set_go_series "$value") || { echo 'Error: could not update the go directive in src/go.mod' >&2; return 1; }
            image=$(set_go_image "$value") || { echo 'Error: could not find one golang image in Containerfile' >&2; return 1; }
        else
            pins=$(set_pin <(printf '%s\n' "$pins") "$key" "$value") ||
                { printf 'Error: could not find one %s line in versions.env\n' "$key" >&2; return 1; }
        fi
    done <<< "$pairs"
    writing=true
    printf '%s\n' "$pins" > "$ROOT/versions.env" &&
        printf '%s\n' "$gomod" > "$ROOT/src/go.mod" &&
        printf '%s\n' "$image" > "$ROOT/Containerfile" &&
        generate --write && generate --check
}

request=$*
# Restore only the worktree, from the index checked above.
undo() {
    if git -C "$ROOT" checkout -- "${files[@]}"; then
        printf 'Error: could not apply %s; the changes were undone.\n' "$request" >&2
    else
        printf 'Error: could not apply %s, and undoing it failed; restore %s from Git.\n' "$request" "${files[*]}" >&2
    fi
}

# An interruption after the first write undoes the update too, so the pins and
# their generated copies never stay out of step. SIGKILL cannot be caught.
writing=false
interrupted() {
    trap - INT TERM HUP
    if [[ $writing == true ]]; then undo; fi
    exit "$1"
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'interrupted 129' HUP

if ! apply_all; then
    undo
    exit 1
fi
writing=false
printf 'Applied %s and regenerated the derived files.\n' "$request"
