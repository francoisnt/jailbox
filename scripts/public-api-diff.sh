#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read a file from the current checkout or from a git ref.
file_at_ref() {
    local ref="$1" path="$2" paths

    if [ -z "$ref" ]; then
        cat "$ROOT_DIR/$path"
    else
        # Missing historical paths are optional; an unsuccessful read is not.
        paths=$(git -C "$ROOT_DIR" ls-tree --name-only "$ref" -- "$path") || return 1
        [ -n "$paths" ] || return 0
        git -C "$ROOT_DIR" show "$ref:$path"
    fi
}

# Extract one array from src/public.sh as a sorted list of values.
public_api_values() {
    local ref="$1" array_name="$2"
    local api_file

    api_file="$(file_at_ref "$ref" "src/public.sh")" || return 1
    if [ -z "$api_file" ]; then
        api_file="$(file_at_ref "$ref" "host/public-api.sh")" || return 1
    fi
    if [ -z "$api_file" ]; then
        api_file="$(file_at_ref "$ref" "lib/public-api.sh")" || return 1
    fi
    [ -n "$api_file" ] || { echo "Error: no public API declarations at $ref" >&2; return 1; }

    printf '%s\n' "$api_file" |
        awk -v array="$array_name" -f "$ROOT_DIR/scripts/lib/public-api-values.awk" |
        sed '/^$/d' |
        sort -u
}

cli_api_values() {
    local ref="$1" split_values categorized

    categorized="$({
        public_api_values "$ref" "CLI_LIFECYCLE_COMMANDS" || return 1
        public_api_values "$ref" "CLI_OTHER_COMMANDS" || return 1
    } | sort -u)" || return 1
    if [ -n "$categorized" ]; then
        { printf '%s\n' "$categorized"; public_api_values "$ref" "CLI_FLAGS_WITH_VALUES"; } | sort -u || return 1
        return
    fi

    split_values="$({
        public_api_values "$ref" "CLI_FLAGS_WITH_VALUES" || return 1
        public_api_values "$ref" "CLI_FLAGS_WITHOUT_VALUES" || return 1
    } | sort -u)" || return 1
    if [ -n "$split_values" ]; then
        printf '%s\n' "$split_values"
    else
        # Releases before value-taking options used one combined declaration.
        public_api_values "$ref" "CLI_FLAGS"
    fi
}

# Return all public API names that participate in release bump decisions.
# FRONTEND_SCALAR_KEYS is absent from refs that declared frontend keys inside
# CONFIG_SCALAR_KEYS; extraction then contributes nothing, so reclassifying a
# key between the two arrays leaves the public name set unchanged.
public_api_names() {
    {
        public_api_values "$1" "CONFIG_SCALAR_KEYS" || return 1
        public_api_values "$1" "CONFIG_ARRAY_KEYS" || return 1
        public_api_values "$1" "FRONTEND_SCALAR_KEYS" || return 1
        cli_api_values "$1" || return 1
    } | sort -u
}

# Compare BASE_REF to the current checkout and print removed, added, or unchanged.
main() {
    local base_ref removed added base_names current_names

    if [ "$#" -ne 1 ]; then
        echo "Usage: scripts/public-api-diff.sh BASE_REF" >&2
        exit 2
    fi

    base_ref="$1"

    base_names=$(public_api_names "$base_ref") || return 1
    current_names=$(public_api_names "") || return 1
    removed=$(comm -23 <(printf '%s\n' "$base_names") <(printf '%s\n' "$current_names")) || return 1
    added=$(comm -13 <(printf '%s\n' "$base_names") <(printf '%s\n' "$current_names")) || return 1

    if [ -n "$removed" ]; then
        printf 'removed\n'
    elif [ -n "$added" ]; then
        printf 'added\n'
    else
        printf 'unchanged\n'
    fi
}

main "$@"
