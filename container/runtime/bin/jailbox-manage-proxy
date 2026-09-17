#!/bin/bash
# Synchronize jailbox's delimited downloader settings without rewriting a
# correct file or following sandbox-controlled links out of the home.
set -euo pipefail

begin="# >>> jailbox managed proxy >>>"
end="# <<< jailbox managed proxy <<<"

validate_file() {
    local file="$1" line in_block=false
    [[ ! -L "$file" ]] || return 1
    [[ -e "$file" ]] || return 0
    [[ -f "$file" && $(stat -c %h "$file") == 1 ]] || return 1
    # Unbalanced/nested markers have no safe ownership boundary. Refuse rather
    # than interpreting arbitrary trailing user content as a managed region.
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$begin") [[ $in_block == false ]] || return 1; in_block=true ;;
            "$end") [[ $in_block == true ]] || return 1; in_block=false ;;
        esac
    done < "$file"
    [[ $in_block == false ]]
}

managed_content() {
    local file="$1" line in_block=false count=0
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$begin") in_block=true; count=$((count + 1)); continue ;;
            "$end") in_block=false; continue ;;
        esac
        if [[ $in_block == true ]]; then printf '%s\n' "$line"; fi
    done < "$file"
    [[ $count == 1 ]]
}

without_managed_blocks() {
    local file="$1" line in_block=false newline
    [[ -f "$file" ]] || return 0
    while :; do
        newline=true
        IFS= read -r line || newline=false
        [[ $newline == true || -n "$line" ]] || break
        case "$line" in
            "$begin") in_block=true ;;
            "$end") in_block=false ;;
            *)
                if [[ $in_block == false ]]; then
                    printf '%s' "$line"
                    [[ $newline == false ]] || printf '\n'
                fi
                ;;
        esac
        [[ $newline == true ]] || break
    done < "$file"
}

matches() {
    local actual
    actual=$(managed_content "$1") || return 1
    [[ "$actual" == "$2" ]]
}

sync_file() (
    local file="$1" content="$2" tmp file_mode=600
    if [[ $mode == enable ]]; then
        matches "$file" "$content" && return 0
    else
        [[ -f "$file" ]] && grep -Fqx "$begin" "$file" || return 0
    fi
    [[ ! -f "$file" ]] || file_mode=$(stat -c %a "$file")
    # Prepare on the home filesystem, then replace atomically. A failed write
    # must never truncate the unrelated user settings in the original file.
    tmp=$(mktemp "$HOME/.jailbox-proxy.XXXXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    without_managed_blocks "$file" > "$tmp"
    if [[ $mode == enable ]]; then
        [[ ! -s "$tmp" ]] || printf '\n' >> "$tmp"
        {
            printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
        } >> "$tmp"
    fi
    if [[ $mode == disable && ! -s "$tmp" ]]; then
        rm -f -- "$file"
    else
        chmod "$file_mode" "$tmp"
        mv -fT -- "$tmp" "$file"
    fi
    rm -f "$tmp"
)

mode=${1:-}
case "$mode" in
    enable|check-enable) proxy_url=${2:?enable requires a proxy URL} ;;
    disable|check-disable) proxy_url="" ;;
    *) printf 'Usage: %s enable <proxy-url>|disable|check-enable <proxy-url>|check-disable\n' "$0" >&2; exit 1 ;;
esac
curl_content="proxy = \"$proxy_url\""
wget_content="use_proxy = on
http_proxy = $proxy_url
https_proxy = $proxy_url"
for file in "$HOME/.curlrc" "$HOME/.wgetrc"; do
    validate_file "$file" || { printf 'Unsafe downloader file or malformed managed block: %s\n' "$file" >&2; exit 1; }
done
case "$mode" in
    check-enable)
        matches "$HOME/.curlrc" "$curl_content" && matches "$HOME/.wgetrc" "$wget_content"
        ;;
    check-disable)
        for file in "$HOME/.curlrc" "$HOME/.wgetrc"; do
            if [[ -f "$file" ]] && grep -Fqx "$begin" "$file"; then exit 1; fi
        done
        ;;
    *)
        sync_file "$HOME/.curlrc" "$curl_content"
        sync_file "$HOME/.wgetrc" "$wget_content"
        ;;
esac
