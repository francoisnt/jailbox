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
    # Every network carries the digest, so no network is created before the
    # current configuration has one.
    assert_config_digest_ready

    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        configure_proxy_network
    else
        if ! up_resource_present "network:$NETWORK_NAME"; then
            track_up_resource "network:$NETWORK_NAME"
            podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$NETWORK_NAME"
        fi
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

    internal_net="${NETWORK_NAME}-internal"
    external_net="${NETWORK_NAME}-external"

    ensure_internal_network "$internal_net"
    if ! up_resource_present "network:$external_net"; then
        track_up_resource "network:$external_net"
        podman network create "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$external_net"
    fi

    # Derive the proxy address from the network's actual subnet rather than
    # recomputing the hash candidate: an existing network may have been
    # created on a fallback subnet after a collision.
    proxy_internal_subnet=$(internal_network_subnet "$internal_net")
    [ -n "$proxy_internal_subnet" ] || die "could not determine subnet of internal network $internal_net"
    proxy_internal_ip=$(proxy_ip_for_subnet "$proxy_internal_subnet")

    NETWORK_STATE[proxy_conf_file]="$SSH_DIR/tinyproxy.conf"
    if [ "$UP_PROXY_STATE" = absent ]; then
        prepare_proxy_files
        render_tinyproxy_filter "${NETWORK_STATE[filter_file]}" "${effective_egress_allow[@]}"
        render_tinyproxy_conf "${NETWORK_STATE[proxy_conf_file]}" "$proxy_internal_subnet"
        track_up_resource "container:$PROXY_NAME"

        echo "🔒 Starting egress proxy (${#effective_egress_allow[@]} allowed hosts)..."
        # Attach both networks at creation so external_net owns the default
        # route. Never reconnect a surviving container to repair attachments.
        podman run -d \
            --name "$PROXY_NAME" \
            "${CONFIG_DIGEST_LABEL_ARGS[@]}" \
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
    elif [ "$UP_PROXY_STATE" != running ]; then
        podman start "$PROXY_NAME"
    fi

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
    local filter_file="$1"
    shift
    mkdir -p "$(dirname "$filter_file")"
    print_tinyproxy_filter "$@" > "$filter_file" || return 1
    # Public policy must be readable by the unprivileged proxy user.
    chmod 644 "$filter_file"
}

# Rendered copy of the packaged tinyproxy.conf plus a launch-time client ACL.
# Without Allow lines tinyproxy accepts any client that can reach port 8888.
render_tinyproxy_conf() {
    local conf_file="$1" subnet="$2"
    mkdir -p "$(dirname "$conf_file")"
    print_tinyproxy_conf "$subnet" > "$conf_file" || return 1
    chmod 644 "$conf_file"
}

# Create the internal egress network, falling back across candidate subnets:
# podman network create --subnet fails outright when another network — a
# different jailbox project's or anything else on the host — already claims
# the range.
ensure_internal_network() {
    local internal_net attempt candidate

    internal_net="$1"
    up_resource_present "network:$internal_net" && return 0

    track_up_resource "network:$internal_net"
    for ((attempt = 0; attempt < 20; attempt++)); do
        candidate=$(proxy_internal_subnet "$attempt")
        if podman network create --internal --disable-dns --subnet "$candidate" \
            "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$internal_net" >/dev/null 2>&1; then
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
    hash="${PROJECT_HASH-}"
    offset=$(jailbox_project_hash_port_offset "$hash") || return 1
    # Stride 7 is coprime with 200, so successive attempts visit distinct
    # octets across the 10.240.{1..200}.0/24 candidate space.
    octet=$((1 + (offset + attempt * 7) % 200))
    printf '10.240.%s.0/24\n' "$octet"
}

proxy_internal_ip() {
    proxy_ip_for_subnet "$(proxy_internal_subnet)"
}

inspect_network_for_up() {
    local name subnet result member members
    initialize_network_state
    for name in "$NETWORK_NAME" "${NETWORK_NAME}-internal" "${NETWORK_NAME}-external"; do
        up_resource_present "network:$name" || continue
        members=$(podman ps -a --filter "network=$name" --format '{{.Names}}') || die "could not inspect members of network '$name'"
        while IFS= read -r member; do
            case "$member" in
                ""|"$CONTAINER_NAME"|"$PROXY_NAME") ;;
                *) refuse_sandbox "network '$name' has unexpected container '$member'; disconnect that container from this network before recovery" ;;
            esac
        done <<< "$members"
        result=$(podman network inspect "$name" --format '{{.Driver}}') || die "could not inspect network '$name'"
        [ "$result" = bridge ] || refuse_sandbox "network '$name' is not a bridge"
        result=$(podman network inspect "$name" --format '{{.Internal}}') || die "could not inspect network '$name'"
        if [ "$name" = "${NETWORK_NAME}-internal" ]; then
            [ "$result" = true ] || refuse_sandbox "network '$name' has external routing"
            result=$(podman network inspect "$name" --format '{{and (not .DNSEnabled) (not .IPv6Enabled) (eq (len .Subnets) 1)}}') || die "could not inspect internal network settings"
            [ "$result" = true ] || refuse_sandbox 'internal network DNS, IPv6, or subnets changed'
            subnet=$(podman network inspect "$name" --format '{{(index .Subnets 0).Subnet}}') || die 'could not inspect internal subnet'
            [[ "$subnet" =~ ^10\.240\.([1-9]|[1-9][0-9]|1[0-9][0-9]|200)\.0/24$ ]] || refuse_sandbox 'unexpected internal subnet'
        else
            [ "$result" = false ] || refuse_sandbox "network '$name' has incompatible routing"
        fi
    done
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        NETWORK_STATE[selected_network]="${NETWORK_NAME}-internal"
        NETWORK_STATE[internal_network]="${NETWORK_NAME}-internal"
        NETWORK_STATE[filter_file]="$SSH_DIR/tinyproxy-filter"
        NETWORK_STATE[proxy_conf_file]="$SSH_DIR/tinyproxy.conf"
        if up_resource_present "network:${NETWORK_NAME}-internal"; then
            subnet=$(podman network inspect "${NETWORK_NAME}-internal" --format '{{(index .Subnets 0).Subnet}}') || die 'could not inspect internal subnet'
            NETWORK_STATE[proxy_url]="http://$(proxy_ip_for_subnet "$subnet"):8888"
            configure_proxy_env
        fi
    else
        NETWORK_STATE[selected_network]="$NETWORK_NAME"
        [ "$UP_PROXY_STATE" = absent ] || refuse_sandbox 'proxy container exists outside requested egress mode'
    fi
    if [ "$UP_DEV_STATE" != absent ] || [ "$UP_PROXY_STATE" != absent ]; then
        up_resource_present "network:${NETWORK_STATE[selected_network]}" || refuse_sandbox 'required network is missing beneath a surviving container'
        if [ -n "${EGRESS_ALLOW[*]-}" ]; then
            up_resource_present "network:${NETWORK_NAME}-external" || refuse_sandbox 'external proxy network is missing beneath a surviving container'
        fi
    fi
}

validate_container_networks() {
    local name="$1" template network network_id created result ip count=1
    local networks=("${NETWORK_STATE[selected_network]}")
    if [ "$name" = "$PROXY_NAME" ]; then
        networks+=("${NETWORK_NAME}-external")
        count=2
    fi
    template="{{if eq (len .NetworkSettings.Networks) $count}}true{{end}}"
    require_container_property "$name" "$template" 'network attachment count'
    created=$(podman container inspect "$name" --format '{{.Created.UnixNano}}') || die "could not inspect creation time of '$name'"
    [[ "$created" =~ ^[1-9][0-9]{0,18}$ ]] || die "invalid creation time for '$name'"
    for network in "${networks[@]}"; do
        network_id=$(podman network inspect "$network" --format '{{.ID}}') || die "could not inspect network identity '$network'"
        [[ "$network_id" =~ ^[a-f0-9]{64}$ ]] || die "invalid network identity for '$network'"
        # Stopped endpoints may omit NetworkID, but a network recreated after
        # this container was created cannot be its original dependency.
        result=$(podman network inspect "$network" --format "{{le .Created.UnixNano $created}}") || die "could not inspect creation time of '$network'"
        [ "$result" = true ] || refuse_sandbox "network '$network' was recreated beneath '$name'"
        # A stopped endpoint may omit its runtime NetworkID. The stored network
        # name remains mandatory; running endpoints must carry the live ID.
        template="{{\$running := .State.Running}}{{with index .NetworkSettings.Networks $(ssh_inspect_quote "$network")}}{{or (eq .NetworkID $(ssh_inspect_quote "$network_id")) (and (not \$running) (eq .NetworkID \"\"))}}{{end}}"
        require_container_property "$name" "$template" "network '$network' attachment"
    done
    if [ "$name" = "$PROXY_NAME" ]; then
        ip=${NETWORK_STATE[proxy_url]#http://}
        ip=${ip%:8888}
        template="{{if .State.Running}}{{with index .NetworkSettings.Networks $(ssh_inspect_quote "${NETWORK_NAME}-internal")}}{{eq .IPAddress $(ssh_inspect_quote "$ip")}}{{end}}{{else}}true{{end}}"
        require_container_property "$name" "$template" 'proxy address'
    fi
}

prepare_proxy_files() {
    local path
    validate_ssh_state_path || return 1
    if [ ! -d "$SSH_DIR" ]; then
        UP_HOST_CREATED+=("$SSH_DIR")
        # New parent directories are private too; leave existing parents unchanged.
        (umask 077; mkdir -p -- "$SSH_DIR")
    fi
    validate_ssh_file "$SSH_DIR" 700 directory || die 'unsafe runtime directory metadata'
    for path in "${NETWORK_STATE[filter_file]}" "${NETWORK_STATE[proxy_conf_file]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            [[ -f "$path" && ! -L "$path" ]] || die "unsafe proxy configuration path '$path'"
        else
            UP_HOST_CREATED+=("$path")
        fi
    done
}

print_tinyproxy_filter() {
    local host escaped
    # Two patterns per domain: exact match and subdomain match. The grouped
    # anchor in (^|\.)domain$ is not honoured by musl's POSIX ERE implementation.
    for host in "$@"; do
        escaped=$(tinyproxy_escape_host "$host") || return 1
        printf '^%s$\n\\.%s$\n' "$escaped" "$escaped"
    done
}

print_tinyproxy_conf() {
    cat "$SCRIPT_DIR/container/tinyproxy/tinyproxy.conf" || return 1
    printf '\n# Rendered at launch: only the internal jailbox network may use the proxy.\nAllow %s\n' "$1"
}

validate_proxy_configuration() {
    local subnet template
    local effective=()
    effective_egress_allowlist effective
    subnet=$(podman network inspect "${NETWORK_NAME}-internal" --format '{{(index .Subnets 0).Subnet}}') || die 'could not inspect proxy subnet'
    if ! validate_ssh_file "${NETWORK_STATE[filter_file]}" 644 file ||
        ! validate_ssh_file "${NETWORK_STATE[proxy_conf_file]}" 644 file; then
        refuse_sandbox 'unsafe proxy configuration files'
    fi
    if ! cmp -s "${NETWORK_STATE[filter_file]}" <(print_tinyproxy_filter "${effective[@]}") ||
        ! cmp -s "${NETWORK_STATE[proxy_conf_file]}" <(print_tinyproxy_conf "$subnet"); then
        refuse_sandbox 'proxy configuration differs from requested policy'
    fi
    require_container_mount "$PROXY_NAME" /etc/tinyproxy/filter bind "${NETWORK_STATE[filter_file]}" false
    require_container_mount "$PROXY_NAME" /etc/tinyproxy/tinyproxy.conf bind "${NETWORK_STATE[proxy_conf_file]}" false
    template='{{range .Mounts}}{{if not (or (eq .Destination "/etc/tinyproxy/filter") (eq .Destination "/etc/tinyproxy/tinyproxy.conf"))}}invalid{{end}}{{end}}true'
    require_container_property "$PROXY_NAME" "$template" 'proxy mount inventory'
    require_container_property "$PROXY_NAME" '{{and (eq .Config.User "tinyproxy") (eq (len .HostConfig.PortBindings) 0)}}' 'proxy user/port policy'
}
