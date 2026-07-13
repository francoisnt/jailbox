# Network setup and optional tinyproxy egress sidecar.

# shellcheck source=host/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-id.sh"

configure_network() {
    FILTER_FILE=""
    PROXY_CONF_FILE=""

    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        configure_proxy_network
    else
        podman network exists "$NETWORK_NAME" 2>/dev/null || \
            podman network create --label "jailbox.project=$PROJECT_DIR" "$NETWORK_NAME"
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
    local internal_net external_net effective_egress_allow proxy_internal_ip proxy_internal_subnet

    effective_egress_allow=()
    while IFS= read -r domain; do
        effective_egress_allow+=("$domain")
    done < <(effective_egress_allowlist)
    FILTER_FILE="$SSH_DIR/tinyproxy-filter"
    render_tinyproxy_filter "$FILTER_FILE" "${effective_egress_allow[@]}"

    echo "📦 Building proxy image..."
    podman build -t "$PROXY_IMAGE" -f "$SCRIPT_DIR/container/tinyproxy/Containerfile" "$SCRIPT_DIR/container/tinyproxy"

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    ensure_internal_network "$internal_net"
    podman network exists "$external_net" 2>/dev/null || \
        podman network create --label "jailbox.project=$PROJECT_DIR" "$external_net"

    # Derive the proxy address from the network's actual subnet rather than
    # recomputing the hash candidate: an existing network may have been
    # created on a fallback subnet after a collision.
    proxy_internal_subnet=$(internal_network_subnet "$internal_net")
    [ -n "$proxy_internal_subnet" ] || die "could not determine subnet of internal network $internal_net"
    proxy_internal_ip=$(proxy_ip_for_subnet "$proxy_internal_subnet")

    PROXY_CONF_FILE="$SSH_DIR/tinyproxy.conf"
    render_tinyproxy_conf "$PROXY_CONF_FILE" "$proxy_internal_subnet"

    if podman container exists "$PROXY_NAME" 2>/dev/null; then
        echo "Replacing existing proxy container: $PROXY_NAME"
    fi
    echo "🔒 Starting egress proxy (${#effective_egress_allow[@]} allowed hosts)..."
    # Attach both networks at start time so external_net remains the primary
    # (default-route) interface. A subsequent `podman network connect` can
    # replace the default route with the newly-added interface, which would
    # cut off the proxy's outbound internet access.
    # --user tinyproxy: run unprivileged from the start. With --cap-drop=ALL a
    # root tinyproxy could not setuid away anyway, so a conf User directive
    # would fail; the account comes from the Alpine tinyproxy package.
    podman run -d \
        --name "$PROXY_NAME" \
        --label "jailbox.project=$PROJECT_DIR" \
        --replace \
        --network "$external_net" \
        --network "$internal_net:ip=$proxy_internal_ip" \
        --user tinyproxy \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev \
        --tmpfs /run:rw,noexec,nosuid,nodev \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        -v "$FILTER_FILE:/etc/tinyproxy/filter:ro,Z" \
        -v "$PROXY_CONF_FILE:/etc/tinyproxy/tinyproxy.conf:ro,Z" \
        "$PROXY_IMAGE"

    JAILBOX_NETWORK="$internal_net"
    JAILBOX_INTERNAL_NETWORK="$internal_net"
    PROXY_URL="http://$proxy_internal_ip:8888"
    configure_proxy_env
}

effective_egress_allowlist() {
    local hosts=("${EGRESS_ALLOW[@]}")

    if [[ -n "$EDITOR_BIN" ]]; then
        case "$(basename "$EDITOR_BIN")" in
            code)
                # main.vscode-cdn.net succeeded vo.msecnd.net as the download
                # CDN; keep both while older VS Code builds remain in use.
                hosts+=(
                    update.code.visualstudio.com
                    vscode.download.prss.microsoft.com
                    main.vscode-cdn.net
                    vo.msecnd.net
                )
                ;;
            codium)
                hosts+=(
                    github.com
                    githubusercontent.com
                )
                ;;
        esac
    fi

    printf '%s\n' "${hosts[@]}" | awk 'NF && !seen[$0]++'
}

configure_proxy_env() {
    local existing_subnet

    # Single source for the proxy URL and no-proxy list. All other modules
    # (editor settings, downloader bootstrap) reference these globals.
    if [ -z "$PROXY_URL" ] && [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        # ssh-config runs without launching: prefer the live network's subnet
        # (it may sit on a collision-fallback candidate), else candidate 0.
        # podman may be absent on this path; internal_network_subnet then
        # returns empty and the hash candidate is used.
        existing_subnet=$(internal_network_subnet "${NETWORK_NAME}-internal")
        if [ -n "$existing_subnet" ]; then
            PROXY_URL="http://$(proxy_ip_for_subnet "$existing_subnet"):8888"
        else
            PROXY_URL="http://$(proxy_internal_ip):8888"
        fi
    fi
    [ -n "$PROXY_URL" ] || PROXY_URL="http://$PROXY_NAME:8888"
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

render_tinyproxy_filter() {
    local filter_file domain escaped

    filter_file="$1"
    shift

    mkdir -p "$(dirname "$filter_file")"
    : > "$filter_file"
    # World-readable: the proxy runs as the unprivileged tinyproxy user while
    # rootless podman maps the host owner to container root. The content is
    # only the public allowlist.
    chmod 644 "$filter_file"
    for domain in "$@"; do
        escaped="$(tinyproxy_escape_host "$domain")"
        # Two patterns per domain: exact match and subdomain match.
        # (^|\.)domain$ looks correct but the ^ inside a group is not
        # honoured by musl libc's POSIX ERE (used in Alpine/tinyproxy).
        printf '^%s$\n' "$escaped" >> "$filter_file"
        printf '\\.%s$\n' "$escaped" >> "$filter_file"
    done
}

# Rendered copy of the packaged tinyproxy.conf plus a launch-time client ACL.
# Without Allow lines tinyproxy accepts any client that can reach port 8888.
render_tinyproxy_conf() {
    local conf_file subnet

    conf_file="$1"
    subnet="$2"
    mkdir -p "$(dirname "$conf_file")"
    {
        cat "$SCRIPT_DIR/container/tinyproxy/tinyproxy.conf"
        printf '\n# Rendered at launch: only the internal jailbox network may use the proxy.\n'
        printf 'Allow %s\n' "$subnet"
    } > "$conf_file"
    chmod 644 "$conf_file"
}

# Create the internal egress network, falling back across candidate subnets:
# podman network create --subnet fails outright when another network — a
# different jailbox project's or anything else on the host — already claims
# the range.
ensure_internal_network() {
    local internal_net attempt candidate

    internal_net="$1"
    podman network exists "$internal_net" 2>/dev/null && return 0

    for attempt in $(seq 0 19); do
        candidate=$(proxy_internal_subnet "$attempt")
        if podman network create --internal --disable-dns --subnet "$candidate" \
            --label "jailbox.project=$PROJECT_DIR" "$internal_net" >/dev/null 2>&1; then
            return 0
        fi
    done
    die "could not allocate a free subnet for internal network $internal_net (tried 20 candidates in 10.240.0.0/16)"
}

internal_network_subnet() {
    podman network inspect "$1" --format '{{ (index .Subnets 0).Subnet }}' 2>/dev/null || true
}

proxy_ip_for_subnet() {
    local prefix

    prefix="${1%/*}"
    printf '%s.2\n' "${prefix%.*}"
}

proxy_internal_subnet() {
    local attempt hash offset octet

    attempt="${1:-0}"
    hash="${PROJECT_HASH:-0}"
    offset=$(jailbox_project_hash_port_offset "$hash")
    # Stride 7 is coprime with 200, so successive attempts visit distinct
    # octets across the 10.240.{1..200}.0/24 candidate space.
    octet=$((1 + (offset + attempt * 7) % 200))
    printf '10.240.%s.0/24\n' "$octet"
}

proxy_internal_ip() {
    proxy_ip_for_subnet "$(proxy_internal_subnet)"
}
