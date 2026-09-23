# Network state and resource validation.

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

configure_proxy_env() {
    local existing_subnet

    # Single source for the proxy URL and no-proxy list. Other modules read
    # these values from the network-owned state map.
    if [ -z "${NETWORK_STATE[proxy_url]}" ] && [ -n "${EGRESS_ALLOW[*]-}" ]; then
        # Preserve a live collision-fallback subnet; before network creation,
        # the deterministic candidate supplies the endpoint.
        existing_subnet=$(internal_network_subnet "${NETWORK_NAME}-internal" || true)
        if [ -n "$existing_subnet" ]; then
            NETWORK_STATE[proxy_url]="http://$(proxy_ip_for_subnet "$existing_subnet"):8888"
        else
            NETWORK_STATE[proxy_url]="http://$(proxy_internal_ip):8888"
        fi
    fi
    [[ "${NETWORK_STATE[proxy_url]}" =~ ^http://([0-9]{1,3}\.){3}[0-9]{1,3}:8888$ ]] || die 'could not determine an internal proxy IPv4 URL'
    NETWORK_STATE[no_proxy]="localhost,127.0.0.1"
    # The client config carries these values. Container startup also receives
    # proxy_url and supplies them through server SetEnv for clients that ignore
    # the SSH Host block's environment directives.
    NETWORK_SSH_SESSION_ENV=(
        "HTTP_PROXY=${NETWORK_STATE[proxy_url]}"
        "HTTPS_PROXY=${NETWORK_STATE[proxy_url]}"
        "http_proxy=${NETWORK_STATE[proxy_url]}"
        "https_proxy=${NETWORK_STATE[proxy_url]}"
        "NO_PROXY=${NETWORK_STATE[no_proxy]}"
        "no_proxy=${NETWORK_STATE[no_proxy]}"
    )
}

# Create the internal egress network, falling back across candidate subnets:
# podman network create --subnet fails outright when another network — a
# different jailbox project's or anything else on the host — already claims
# the range.
ensure_internal_network() {
    local internal_net attempt candidate diagnostic

    internal_net="$1"
    observed_resource_present "network:$internal_net" && return 0

    record_launch_resource_attempt "network:$internal_net"
    for ((attempt = 0; attempt < 20; attempt++)); do
        candidate=$(proxy_internal_subnet "$attempt") || return 1
        if diagnostic=$(podman network create --internal --disable-dns --subnet "$candidate" \
            "${CONFIG_DIGEST_LABEL_ARGS[@]}" "$internal_net" 2>&1 >/dev/null); then
            return 0
        fi
    done
    printf 'Last Podman network creation diagnostic: %s\n' "${diagnostic:-no diagnostic returned}" >&2
    die "could not create internal network $internal_net (tried 20 subnet candidates in 10.240.0.0/16)"
}

internal_network_subnet() {
    podman network inspect "$1" --format '{{ (index .Subnets 0).Subnet }}' 2>/dev/null
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

# Read-only engine checks against OBSERVED_* and requested policy. Refreshes
# NETWORK_STATE and SSH proxy settings; does not create, reconnect, or repair
# networks. Failed observation and incompatible dependencies refuse reuse.
inspect_network_compatibility() {
    local name subnet result member members
    initialize_network_state
    for name in "$NETWORK_NAME" "${NETWORK_NAME}-internal" "${NETWORK_NAME}-external"; do
        observed_resource_present "network:$name" || continue
        members=$(podman ps -a --filter "network=$name" --format '{{.Names}}') || die "could not inspect members of network '$name'"
        while IFS= read -r member; do
            case "$member" in
                ""|"$CONTAINER_NAME"|"$PROXY_NAME") ;;
                *) die "network '$name' has unexpected container '$member'; disconnect that container from this network before retrying" ;;
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
        if observed_resource_present "network:${NETWORK_NAME}-internal"; then
            subnet=$(podman network inspect "${NETWORK_NAME}-internal" --format '{{(index .Subnets 0).Subnet}}') || die 'could not inspect internal subnet'
            NETWORK_STATE[proxy_url]="http://$(proxy_ip_for_subnet "$subnet"):8888"
            configure_proxy_env
        fi
    else
        NETWORK_STATE[selected_network]="$NETWORK_NAME"
        [ "$OBSERVED_PROXY_STATE" = absent ] || refuse_sandbox 'proxy container exists outside requested egress mode'
    fi
    if [ "$OBSERVED_DEV_STATE" != absent ] || [ "$OBSERVED_PROXY_STATE" != absent ]; then
        observed_resource_present "network:${NETWORK_STATE[selected_network]}" || refuse_sandbox 'required network is missing beneath a surviving container'
        if [ -n "${EGRESS_ALLOW[*]-}" ]; then
            observed_resource_present "network:${NETWORK_NAME}-external" || refuse_sandbox 'external proxy network is missing beneath a surviving container'
        fi
    fi
}

validate_container_networks() {
    local name="$1" template network network_id created result ip count=1
    local -a properties=()
    local networks=("${NETWORK_STATE[selected_network]}")
    if [ "$name" = "$PROXY_NAME" ]; then
        networks+=("${NETWORK_NAME}-external")
        count=2
    fi
    template="{{if eq (len .NetworkSettings.Networks) $count}}true{{end}}"
    properties+=("$template" 'network attachment count')
    created=$(podman container inspect "$name" --format '{{.Created.UnixNano}}') || die "could not inspect creation time of '$name'"
    [[ "$created" =~ ^[1-9][0-9]{0,18}$ ]] || die "invalid creation time for '$name'"
    for network in "${networks[@]}"; do
        result=$(podman network inspect "$network" --format "{{.ID}} {{le .Created.UnixNano $created}}") || die "could not inspect network identity and creation time '$network'"
        network_id=${result%% *}
        result=${result#* }
        [[ "$network_id" =~ ^[a-f0-9]{64}$ ]] || die "invalid network identity for '$network'"
        # Stopped endpoints may omit NetworkID, but a network recreated after
        # this container was created cannot be its original dependency.
        [ "$result" = true ] || refuse_sandbox "network '$network' was recreated beneath '$name'"
        # Podman 4.9 reports the network name as NetworkID, even when running.
        # Require the named attachment and retain the creation-time check above
        # so a recreated network cannot pass by reusing its name.
        template="{{with index .NetworkSettings.Networks $(ssh_inspect_quote "$network")}}true{{end}}"
        properties+=("$template" "network '$network' attachment presence")
        template="{{with index .NetworkSettings.Networks $(ssh_inspect_quote "$network")}}{{or (eq .NetworkID $(ssh_inspect_quote "$network_id")) (eq .NetworkID $(ssh_inspect_quote "$network")) (eq .NetworkID \"\")}}{{end}}"
        properties+=("$template" "network '$network' attachment identity")
        # Only stopped endpoints may omit their runtime identity. Keep all
        # attachment predicates in one container inspection at this boundary.
        template="{{\$running := .State.Running}}{{with index .NetworkSettings.Networks $(ssh_inspect_quote "$network")}}{{or (ne .NetworkID \"\") (not \$running)}}{{end}}"
        properties+=("$template" "network '$network' stopped attachment")
    done
    if [ "$name" = "$PROXY_NAME" ]; then
        ip=${NETWORK_STATE[proxy_url]#http://}
        ip=${ip%:8888}
        template="{{if .State.Running}}{{with index .NetworkSettings.Networks $(ssh_inspect_quote "${NETWORK_NAME}-internal")}}{{eq .IPAddress $(ssh_inspect_quote "$ip")}}{{end}}{{else}}true{{end}}"
        properties+=("$template" 'proxy address')
    fi
    require_container_properties "$name" "${properties[@]}"
}
