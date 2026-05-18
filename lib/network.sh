# Network setup and optional tinyproxy egress sidecar.

configure_network() {
    FILTER_FILE=""
    cleanup_filter_file() { [ -n "$FILTER_FILE" ] && rm -f "$FILTER_FILE"; }
    trap cleanup_filter_file EXIT

    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        configure_proxy_network
    else
        podman network exists "$NETWORK_NAME" 2>/dev/null || podman network create "$NETWORK_NAME"
        JAILBOX_NETWORK="$NETWORK_NAME"
        PROXY_ENV=()
    fi
}

configure_proxy_network() {
    local domain internal_net external_net

    FILTER_FILE=$(mktemp)
    for domain in "${EGRESS_ALLOW[@]}"; do
        printf '(^|\\.)%s$\n' "$(tinyproxy_escape_host "$domain")" >> "$FILTER_FILE"
    done

    echo "📦 Building proxy image..."
    podman build -t "$PROXY_IMAGE" -f "$SCRIPT_DIR/Containerfile.proxy" "$SCRIPT_DIR"

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    podman network exists "$internal_net" 2>/dev/null || podman network create --internal "$internal_net"
    podman network exists "$external_net" 2>/dev/null || podman network create "$external_net"

    echo "🔒 Starting egress proxy (${#EGRESS_ALLOW[@]} allowed hosts)..."
    podman run -d \
        --name "$PROXY_NAME" \
        --replace \
        --network "$external_net" \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        -v "$FILTER_FILE:/etc/tinyproxy/filter:ro" \
        "$PROXY_IMAGE"

    podman network connect "$internal_net" "$PROXY_NAME"
    echo "⚠️  Proxy is best-effort (env-based). Some tools may bypass it."

    JAILBOX_NETWORK="$internal_net"
    JAILBOX_INTERNAL_NETWORK="$internal_net"
    PROXY_ENV=(
        --env "HTTP_PROXY=http://$PROXY_NAME:8888"
        --env "HTTPS_PROXY=http://$PROXY_NAME:8888"
        --env "http_proxy=http://$PROXY_NAME:8888"
        --env "https_proxy=http://$PROXY_NAME:8888"
        --env "NO_PROXY=localhost,127.0.0.1"
        --env "no_proxy=localhost,127.0.0.1"
    )
}

tinyproxy_escape_host() {
    printf '%s\n' "$1" | sed 's/\./\\./g'
}
