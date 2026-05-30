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
    local current_proxy_state expected_proxy_state

    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        expected_proxy_state="proxy = \"$PROXY_URL\"
http_proxy = $PROXY_URL
https_proxy = $PROXY_URL"
        current_proxy_state=$(ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" 'bash -s' <<'REMOTE' 2>/dev/null || true
read_managed_line() {
    local file="$1"
    local pattern="$2"

    awk -v pattern="$pattern" '
    $0 == "# >>> jailbox managed proxy >>>" { in_block = 1; next }
    $0 == "# <<< jailbox managed proxy <<<" { in_block = 0; next }
    in_block && $0 ~ pattern { print; found = 1; exit }
    END { if (!found) exit 1 }
' "$file"
}

read_managed_line "$HOME/.curlrc" "^proxy = \""
read_managed_line "$HOME/.wgetrc" "^http_proxy = "
read_managed_line "$HOME/.wgetrc" "^https_proxy = "
REMOTE
)
        [ "$current_proxy_state" = "$expected_proxy_state" ] && return 0

        echo "🔧 Configuring downloader proxy compatibility..."
        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
            "PROXY_URL=$(printf '%q' "$PROXY_URL") bash -s" <<'REMOTE'
jailbox-manage-proxy enable "$PROXY_URL"
REMOTE
    else
        if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" 'bash -s' <<'REMOTE' 2>/dev/null
for file in "$HOME/.curlrc" "$HOME/.wgetrc"; do
    [[ -f "$file" ]] && grep -Fqx "# >>> jailbox managed proxy >>>" "$file" && exit 0
done
exit 1
REMOTE
        then
            return 0
        fi

        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
            "jailbox-manage-proxy disable"
    fi
}
