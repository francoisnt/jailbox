# Managed downloader proxy configuration for egress-mode editor bootstrap.
#
# VSCodium/VS Code Remote SSH bootstrap runs a downloader script before the
# SSH session environment is fully established, so HTTP_PROXY/HTTPS_PROXY env
# vars set via SSH SetEnv may not yet be visible. Managed blocks in ~/.curlrc
# and ~/.wgetrc make the tinyproxy sidecar available to curl/wget regardless
# of session env inheritance, covering the bootstrap window.
#
# Blocks are written to the managed jailbox home volume only — never to the
# project tree or host home. Non-jailbox content in these files is preserved.

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
    local tmp existed

    existed=0
    [[ -f "$file" ]] && existed=1

    tmp=$(mktemp)
    if [[ $existed -eq 1 ]]; then
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
    # Preserve the original mode on existing files; apply 600 only to new ones.
    if [[ $existed -eq 0 ]]; then
        chmod 600 "$file"
    fi
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

    # Remove the file entirely if only whitespace remains; avoids leaving a
    # zero-byte or blank dotfile that the user did not create.
    if [[ ! -s "$tmp" ]] || ! grep -qv '^[[:space:]]*$' "$tmp"; then
        rm -f "$file" "$tmp"
        return 0
    fi

    cat "$tmp" > "$file"
    rm -f "$tmp"
}

remove_managed_block "$HOME/.curlrc"
remove_managed_block "$HOME/.wgetrc"
REMOTE
    fi
}
