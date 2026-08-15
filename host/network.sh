# Network setup and optional tinyproxy egress sidecar.

# shellcheck source=host/project-id.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project-id.sh"

declare -A NETWORK_STATE=(
    [selected_network]=""
    [internal_network]=""
    [proxy_url]=""
    [no_proxy]=""
    [filter_file]=""
    [proxy_conf_file]=""
)
# Network owns these outputs. Container launch consumes selected_network;
# validation consumes internal_network; editor/downloader configuration consumes
# proxy_url and no_proxy; proxy startup alone consumes the rendered file paths.
NETWORK_SSH_SESSION_ENV=()

initialize_network_state() {
    NETWORK_STATE=(
        [selected_network]=""
        [internal_network]=""
        [proxy_url]=""
        [no_proxy]=""
        [filter_file]=""
        [proxy_conf_file]=""
    )
    NETWORK_SSH_SESSION_ENV=()
}

configure_network() {
    initialize_network_state

    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        configure_proxy_network
    else
        podman network exists "$NETWORK_NAME" 2>/dev/null || \
            podman network create --label "jailbox.project=$PROJECT_DIR" "$NETWORK_NAME"
        NETWORK_STATE[selected_network]="$NETWORK_NAME"
        NETWORK_SSH_SESSION_ENV=()
        NETWORK_STATE[proxy_url]=""
        NETWORK_STATE[no_proxy]=""
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

    effective_egress_allowlist effective_egress_allow
    NETWORK_STATE[filter_file]="$SSH_DIR/tinyproxy-filter"
    render_tinyproxy_filter "${NETWORK_STATE[filter_file]}" "${effective_egress_allow[@]}"

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

    NETWORK_STATE[proxy_conf_file]="$SSH_DIR/tinyproxy.conf"
    render_tinyproxy_conf "${NETWORK_STATE[proxy_conf_file]}" "$proxy_internal_subnet"

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
        -v "${NETWORK_STATE[filter_file]}:/etc/tinyproxy/filter:ro,Z" \
        -v "${NETWORK_STATE[proxy_conf_file]}:/etc/tinyproxy/tinyproxy.conf:ro,Z" \
        "$PROXY_IMAGE"

    NETWORK_STATE[selected_network]="$internal_net"
    NETWORK_STATE[internal_network]="$internal_net"
    NETWORK_STATE[proxy_url]="http://$proxy_internal_ip:8888"
    configure_proxy_env
}

effective_egress_allowlist() {
    local -n result="$1"
    local host
    local hosts=("${EGRESS_ALLOW[@]}")
    local -A seen=()

    result=()

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

    for host in "${hosts[@]}"; do
        [ -n "$host" ] || continue
        # Configured hosts are validated before this function is called; the
        # remaining values are fixed editor domains declared above.
        [[ -v seen[$host] ]] && continue
        seen["$host"]=1
        result+=("$host")
    done
}

configure_proxy_env() {
    local existing_subnet

    # Single source for the proxy URL and no-proxy list. Other modules read
    # these values from the network-owned state map.
    if [ -z "${NETWORK_STATE[proxy_url]}" ] && [ -n "${EGRESS_ALLOW[*]-}" ]; then
        # ssh-config runs without launching: prefer the live network's subnet
        # (it may sit on a collision-fallback candidate), else candidate 0.
        # podman may be absent on this path; internal_network_subnet then
        # returns empty and the hash candidate is used.
        existing_subnet=$(internal_network_subnet "${NETWORK_NAME}-internal")
        if [ -n "$existing_subnet" ]; then
            NETWORK_STATE[proxy_url]="http://$(proxy_ip_for_subnet "$existing_subnet"):8888"
        else
            NETWORK_STATE[proxy_url]="http://$(proxy_internal_ip):8888"
        fi
    fi
    [ -n "${NETWORK_STATE[proxy_url]}" ] || NETWORK_STATE[proxy_url]="http://$PROXY_NAME:8888"
    NETWORK_STATE[no_proxy]="localhost,127.0.0.1"
    # Rendered into the generated SSH Host block via SetEnv. sshd creates fresh
    # session environments, so client-side SetEnv is the reliable way to expose
    # proxy settings to editor terminals and tools.
    NETWORK_SSH_SESSION_ENV=(
        "HTTP_PROXY=${NETWORK_STATE[proxy_url]}"
        "HTTPS_PROXY=${NETWORK_STATE[proxy_url]}"
        "http_proxy=${NETWORK_STATE[proxy_url]}"
        "https_proxy=${NETWORK_STATE[proxy_url]}"
        "NO_PROXY=${NETWORK_STATE[no_proxy]}"
        "no_proxy=${NETWORK_STATE[no_proxy]}"
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

    for ((attempt = 0; attempt < 20; attempt++)); do
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
