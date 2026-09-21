# Up synchronizes only jailbox-managed blocks. The manager validates framing
# and file types before writing either file, and leaves correct files intact.
configure_downloader_proxy() {
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        validation_ssh "jailbox-manage-proxy enable $(printf '%q' "${NETWORK_STATE[proxy_url]}")"
    else
        validation_ssh 'jailbox-manage-proxy disable'
    fi
}
