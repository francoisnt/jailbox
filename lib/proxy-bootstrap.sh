# Managed downloader proxy configuration for egress-mode editor bootstrap.

configure_downloader_proxy() {
    local proxy_url

    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        proxy_url="http://$PROXY_NAME:8888"
        echo "🔧 Configuring downloader proxy compatibility..."
        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "JAILBOX_PROXY_URL='$proxy_url' bash -s" <<'REMOTE'
set -euo pipefail

begin="# >>> jailbox managed proxy >>>"
end="# <<< jailbox managed proxy <<<"

update_managed_block() {
    local file="$1"
    local content="$2"
    local tmp

    tmp=$(mktemp)
    if [[ -f "$file" ]]; then
        awk -v begin="$begin" -v end="$end" '
            $0 == begin { in_block = 1; next }
            $0 == end { in_block = 0; next }
            !in_block { print }
        ' "$file" > "$tmp"
    fi

    {
        cat "$tmp"
        if [[ -s "$tmp" ]]; then
            printf '\n'
        fi
        printf '%s\n' "$begin"
        printf '%s\n' "$content"
        printf '%s\n' "$end"
    } > "$file"
    chmod 600 "$file"
    rm -f "$tmp"
}

update_managed_block "$HOME/.curlrc" "proxy = \"$JAILBOX_PROXY_URL\""
update_managed_block "$HOME/.wgetrc" "use_proxy = on
http_proxy = $JAILBOX_PROXY_URL
https_proxy = $JAILBOX_PROXY_URL"
REMOTE
    else
        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "bash -s" <<'REMOTE'
set -euo pipefail

begin="# >>> jailbox managed proxy >>>"
end="# <<< jailbox managed proxy <<<"

remove_managed_block() {
    local file="$1"
    local tmp

    [[ -f "$file" ]] || return 0
    grep -Fqx "$begin" "$file" || return 0

    tmp=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block { print }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    chmod 600 "$file"
    rm -f "$tmp"
}

remove_managed_block "$HOME/.curlrc"
remove_managed_block "$HOME/.wgetrc"
REMOTE
    fi
}
