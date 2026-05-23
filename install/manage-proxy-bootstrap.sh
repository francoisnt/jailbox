#!/bin/bash
# Manage jailbox proxy configuration blocks in ~/.curlrc and ~/.wgetrc.
#
# Usage:
#   jailbox-manage-proxy enable <proxy-url>
#   jailbox-manage-proxy disable
#
# Justification for bash: the container always installs bash (install/setup.sh)
# and the original inline remote scripts required bash for local, [[]], and
# set -euo pipefail. Requires bash for function-local variables and pipefail.
set -euo pipefail

begin="# >>> jailbox managed proxy >>>"
end="# <<< jailbox managed proxy <<<"

update_managed_block() {
    local file="$1"
    local content="$2"
    local existed tmp

    existed=0
    [[ -f "$file" ]] && existed=1

    tmp=$(mktemp)
    if [[ $existed -eq 1 ]]; then
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { in_block = 1; next }
            $0 == end   { in_block = 0; next }
            !in_block   { print }
        ' "$file" > "$tmp"
    fi

    {
        cat "$tmp"
        [[ -s "$tmp" ]] && printf '\n'
        printf '%s\n' "$begin"
        printf '%s\n' "$content"
        printf '%s\n' "$end"
    } > "$file"
    # Preserve the original mode on existing files; apply 600 only to new ones.
    [[ $existed -eq 0 ]] && chmod 600 "$file"
    rm -f "$tmp"
}

remove_managed_block() {
    local file="$1"
    local tmp

    [[ -f "$file" ]] || return 0
    grep -Fqx "$begin" "$file" || return 0

    tmp=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { in_block = 1; next }
        $0 == end   { in_block = 0; next }
        !in_block   { print }
    ' "$file" > "$tmp"

    # Remove the file entirely if only whitespace remains; avoids leaving a
    # zero-byte or blank dotfile that the user did not create.
    if [[ ! -s "$tmp" ]] || ! grep -qv '^[[:space:]]*$' "$tmp"; then
        rm -f "$file" "$tmp"
        return 0
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

case "${1:-}" in
    enable)
        proxy_url="${2:?enable requires a proxy URL}"
        update_managed_block "$HOME/.curlrc" "proxy = \"$proxy_url\""
        update_managed_block "$HOME/.wgetrc" "use_proxy = on
http_proxy = $proxy_url
https_proxy = $proxy_url"
        ;;
    disable)
        remove_managed_block "$HOME/.curlrc"
        remove_managed_block "$HOME/.wgetrc"
        ;;
    *)
        printf 'Usage: %s enable <proxy-url>|disable\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
