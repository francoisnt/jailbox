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
    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        echo "🔧 Configuring downloader proxy compatibility..."
        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
            "jailbox-manage-proxy enable '$PROXY_URL'"
    else
        ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
            "jailbox-manage-proxy disable"
    fi
}
