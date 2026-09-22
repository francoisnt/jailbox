# resources — downloader

# Up synchronizes only jailbox-managed blocks. The manager validates framing
# and file types before writing either file, and leaves correct files intact.
configure_downloader_proxy() {
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        validation_ssh "jailbox-manage-proxy enable $(printf '%q' "${NETWORK_STATE[proxy_url]}")"
    else
        validation_ssh 'jailbox-manage-proxy disable'
    fi
}

check_downloader_proxy_config() {
    validation_ssh "jailbox-manage-proxy check-enable $(printf '%q' "${NETWORK_STATE[proxy_url]}")" || refuse_downloader_sync "managed downloader settings are not synchronized"
}

check_downloader_proxy_config_absent() {
    validation_ssh 'jailbox-manage-proxy check-disable' || refuse_downloader_sync "stale managed downloader settings remain"
}
