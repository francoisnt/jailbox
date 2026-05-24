# Network setup and optional tinyproxy egress sidecar.

configure_network() {
    FILTER_FILE=""
    cleanup_filter_file() { if [ -n "$FILTER_FILE" ]; then rm -f "$FILTER_FILE"; fi; }
    trap cleanup_filter_file EXIT

    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        configure_proxy_network
    else
        podman network exists "$NETWORK_NAME" 2>/dev/null || podman network create "$NETWORK_NAME"
        JAILBOX_NETWORK="$NETWORK_NAME"
        SSH_SESSION_ENV=()
        PROXY_URL=""
        PROXY_NO_PROXY=""
    fi
}

configure_proxy_network() {
    # Egress enforcement model: direct container egress is blocked by an
    # internal-only Podman network (no external route). Outbound HTTP(S) is
    # brokered exclusively through the tinyproxy sidecar, which enforces the
    # EGRESS_ALLOW domain allowlist. Enforcement is proxy-mediated
    # (protocol/domain filter), not per-packet or firewall-level.
    #
    # Rootless, zero-capability Podman intentionally avoids NET_ADMIN,
    # iptables/nftables, and TUN/TProxy interception. Hostname-aware
    # transparent filtering would require one of those mechanisms. The chosen
    # topology trades transparent filtering for a simpler, capability-free
    # model: tools must cooperate with proxy configuration (HTTP_PROXY /
    # HTTPS_PROXY env, curlrc, wgetrc) to reach allowed hosts.
    local domain internal_net external_net

    FILTER_FILE=$(mktemp)
    for domain in "${EGRESS_ALLOW[@]}"; do
        local escaped
        escaped="$(tinyproxy_escape_host "$domain")"
        # Two patterns per domain: exact match and subdomain match.
        # (^|\.)domain$ looks correct but the ^ inside a group is not
        # honoured by musl libc's POSIX ERE (used in Alpine/tinyproxy).
        printf '^%s$\n'   "$escaped" >> "$FILTER_FILE"
        printf '\\.%s$\n' "$escaped" >> "$FILTER_FILE"
    done

    echo "📦 Building proxy image..."
    podman build -t "$PROXY_IMAGE" -f "$SCRIPT_DIR/container/tinyproxy/Containerfile" "$SCRIPT_DIR/container/tinyproxy"

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    podman network exists "$internal_net" 2>/dev/null || podman network create --internal "$internal_net"
    podman network exists "$external_net" 2>/dev/null || podman network create "$external_net"

    if podman container exists "$PROXY_NAME" 2>/dev/null; then
        echo "Replacing existing proxy container: $PROXY_NAME"
    fi
    echo "🔒 Starting egress proxy (${#EGRESS_ALLOW[@]} allowed hosts)..."
    # Attach both networks at start time so external_net remains the primary
    # (default-route) interface. A subsequent `podman network connect` can
    # replace the default route with the newly-added interface, which would
    # cut off the proxy's outbound internet access.
    podman run -d \
        --name "$PROXY_NAME" \
        --replace \
        --network "$external_net" \
        --network "$internal_net" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        -v "$FILTER_FILE:/etc/tinyproxy/filter:ro" \
        "$PROXY_IMAGE"

    JAILBOX_NETWORK="$internal_net"
    JAILBOX_INTERNAL_NETWORK="$internal_net"
    configure_proxy_env
}

configure_proxy_env() {
    # Single source for the proxy URL and no-proxy list. All other modules
    # (editor settings, downloader bootstrap) reference these globals rather
    # than reconstructing http://$PROXY_NAME:8888 independently.
    PROXY_URL="http://$PROXY_NAME:8888"
    PROXY_NO_PROXY="localhost,127.0.0.1"
    # Rendered into the generated SSH Host block via SetEnv. sshd creates fresh
    # session environments, so client-side SetEnv is the reliable way to expose
    # proxy settings to editor terminals and tools.
    SSH_SESSION_ENV=(
        "HTTP_PROXY=$PROXY_URL"
        "HTTPS_PROXY=$PROXY_URL"
        "http_proxy=$PROXY_URL"
        "https_proxy=$PROXY_URL"
        "NO_PROXY=$PROXY_NO_PROXY"
        "no_proxy=$PROXY_NO_PROXY"
    )
}

tinyproxy_escape_host() {
    printf '%s\n' "$1" | sed 's/\./\\./g'
}
