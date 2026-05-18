#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read a file from the current checkout or from a git ref.
file_at_ref() {
    local ref="$1" path="$2"

    if [ -z "$ref" ]; then
        cat "$ROOT_DIR/$path"
    else
        git -C "$ROOT_DIR" show "$ref:$path" 2>/dev/null || true
    fi
}

# Extract one array from lib/public-api.sh as a sorted list of values.
public_api_values() {
    local ref="$1" array_name="$2"

    file_at_ref "$ref" "lib/public-api.sh" |
        awk -v array="$array_name" '
            $0 ~ "^[[:space:]]*" array "=[(]" { in_array = 1; next }
            in_array && /^[[:space:]]*[)]/ { in_array = 0; next }
            in_array {
                gsub(/#.*/, "")
                gsub(/["'\''"]/, "")
                for (i = 1; i <= NF; i++) print $i
            }
        ' |
        sed '/^$/d' |
        sort -u
}

# Return all public API names that participate in release bump decisions.
public_api_names() {
    {
        public_api_values "$1" "CONFIG_SCALAR_KEYS"
        public_api_values "$1" "CONFIG_ARRAY_KEYS"
        public_api_values "$1" "CLI_FLAGS"
    } | sort -u
}

# Compare BASE_REF to the current checkout and print removed, added, or unchanged.
main() {
    local base_ref removed added

    if [ "$#" -ne 1 ]; then
        echo "Usage: scripts/public-api-diff.sh BASE_REF" >&2
        exit 2
    fi

    base_ref="$1"

    removed=$(comm -23 <(public_api_names "$base_ref") <(public_api_names ""))
    added=$(comm -13 <(public_api_names "$base_ref") <(public_api_names ""))

    if [ -n "$removed" ]; then
        printf 'removed\n'
    elif [ -n "$added" ]; then
        printf 'added\n'
    else
        printf 'unchanged\n'
    fi
}

main "$@"
