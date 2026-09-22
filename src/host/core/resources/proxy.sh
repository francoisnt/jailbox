# resources — proxy

validate_proxy_ready() {
    [ -n "${EGRESS_ALLOW[*]-}" ] || return 0
    local ip response denied gateway
    denied=$(proxy_denied_test_host)
    ip=${NETWORK_STATE[proxy_url]#http://}; ip=${ip%:8888}
    gateway=$(podman container inspect "$PROXY_NAME" --format \
        "{{with index .NetworkSettings.Networks $(ssh_inspect_quote "${NETWORK_NAME}-external")}}{{.Gateway}}{{end}}") || \
        die 'could not inspect proxy external gateway'
    [[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || refuse_sandbox 'proxy external gateway is missing or invalid'
    # A broken local default route is a readiness failure, not an upstream
    # outage. Compare kernel routing evidence with the external attachment.
    [[ -f "$SCRIPT_DIR/container/checks/proxy-route.awk" ]] || \
        refuse_local_validation 'could not read local proxy validation payload; repair the jailbox installation before retrying'
    podman exec -i -e "EXPECTED_GATEWAY=$gateway" "$PROXY_NAME" awk -f - /proc/net/route < "$SCRIPT_DIR/container/checks/proxy-route.awk" >/dev/null || refuse_sandbox 'proxy external default route is not ready'
    # Probe from the proxy's internal address, which its ACL permits, even when
    # the development container is stopped. Positive 403 evidence distinguishes
    # policy denial from DNS/transport failure. nc writes no persistent files.
    response=$(podman exec "$PROXY_NAME" sh -c \
        'printf "GET http://%s/ HTTP/1.0\r\nHost: %s\r\n\r\n" "$2" "$2" | nc -w 5 "$1" 8888' sh "$ip" "$denied") || refuse_sandbox 'proxy readiness probe failed'
    [[ "$response" == HTTP/1.[01]' 403 '* ]] || refuse_sandbox 'proxy did not demonstrate allowlist denial'
}

check_proxy_egress_denied() {
    local result denied status attempt attempts=1 request_timeout=8
    denied=$(proxy_denied_test_host)
    # A newly started dependency may accept its own local probe before it is
    # reachable from an already-running development container. Retry transport
    # readiness only after starting/creating that dependency, never an observed
    # policy failure or an independently checkable pre-existing health failure.
    # Recreating a proxy changes its MAC while retaining its IP. The surviving
    # development container can temporarily retain the old ARP mapping. Allow
    # roughly a minute of transport retries without changing its network state.
    if [ "${UP_PROXY_STATE:-running}" != running ]; then
        attempts=16
        request_timeout=3
    fi
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        status=0
        result=$(validation_ssh "curl -q --noproxy '' --proxy $(printf '%q' "${NETWORK_STATE[proxy_url]}") --silent --show-error --connect-timeout 3 --max-time $request_timeout --output /dev/null --write-out '%{http_code}' http://$denied/") || status=$?
        if [ "$status" -eq 0 ]; then
            [ "$result" = 403 ] || refuse_sandbox 'proxy allowed a host outside the allowlist'
            return 0
        fi
        case "$status" in
            7|28) ;; # Connection refused/unreachable or transport timeout.
            *) break ;;
        esac
        [ "$attempt" -lt "$attempts" ] || break
        printf 'Waiting for development-to-proxy connectivity (%s/%s)...\n' "$attempt" "$attempts" >&2
        sleep 1
    done
    refuse_sandbox 'proxy transport failed; policy denial is unverified'
}

proxy_denied_test_host() {
    local candidate host matched attempt=0
    while :; do
        candidate="jailbox-egress-denied-$attempt.invalid"
        matched=false
        for host in "${EGRESS_ALLOW[@]}"; do
            host=${host,,}
            if [[ "$candidate" = "$host" || "$candidate" = *."$host" ]]; then matched=true; break; fi
        done
        if [ "$matched" = false ]; then printf '%s\n' "$candidate"; return 0; fi
        attempt=$((attempt + 1))
    done
}

check_proxy_egress_allowed() {
    local domain
    domain=${EGRESS_ALLOW[0]}
    if ! validation_ssh "curl -q --noproxy '' --proxy $(printf '%q' "${NETWORK_STATE[proxy_url]}") -fsS --connect-timeout 3 --max-time 8 $(printf '%q' "https://$domain/") >/dev/null"; then
        printf 'Warning: upstream availability for %s was not verified; local proxy policy/readiness checks passed.\n' "$domain" >&2
    fi
}

effective_egress_allowlist() {
    # shellcheck disable=SC2178 # Nameref to the caller-owned array.
    local -n allowlist_result="$1"
    local sorted_hosts
    local hosts=("${EGRESS_ALLOW[@]}")

    allowlist_result=()
    [ -n "${EGRESS_ALLOW[*]-}" ] || return 0

    # Match the digest's set semantics: validated hosts contain no newlines.
    # Capture the producer status before publishing the array to the caller.
    sorted_hosts=$(printf '%s\n' "${hosts[@]}" | LC_ALL=C sort -u) || return 1
    # shellcheck disable=SC2034 # Output is read through the caller name.
    mapfile -t allowlist_result <<< "$sorted_hosts"
}

tinyproxy_escape_host() {
    printf '%s\n' "$1" | sed 's/\./\\./g'
}

render_tinyproxy_filter() {
    local filter_file="$1" parent
    shift
    parent=$(dirname "$filter_file") || return 1
    mkdir -p "$parent" || return 1
    print_tinyproxy_filter "$@" > "$filter_file" || return 1
    # Public policy must be readable by the unprivileged proxy user.
    chmod 644 "$filter_file"
}

# Rendered copy of the packaged tinyproxy.conf plus a launch-time client ACL.
# Without Allow lines tinyproxy accepts any client that can reach port 8888.
render_tinyproxy_conf() {
    local conf_file="$1" subnet="$2" parent
    parent=$(dirname "$conf_file") || return 1
    mkdir -p "$parent" || return 1
    print_tinyproxy_conf "$subnet" > "$conf_file" || return 1
    chmod 644 "$conf_file"
}

prepare_proxy_files() {
    local path
    validate_ssh_state_path || return 1
    if [ ! -d "$SSH_DIR" ]; then
        track_up_host_path "$SSH_DIR"
        # New parent directories are private too; leave existing parents unchanged.
        (umask 077; mkdir -p -- "$SSH_DIR") || return 1
    fi
    validate_ssh_file "$SSH_DIR" 700 directory || die 'unsafe runtime directory metadata'
    for path in "${NETWORK_STATE[filter_file]}" "${NETWORK_STATE[proxy_conf_file]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            [[ -f "$path" && ! -L "$path" ]] || die "unsafe proxy configuration path '$path'"
        else
            track_up_host_path "$path"
        fi
    done
}

print_tinyproxy_filter() {
    local host escaped
    # Two patterns per domain: exact match and subdomain match. The grouped
    # anchor in (^|\.)domain$ is not honoured by musl's POSIX ERE implementation.
    for host in "$@"; do
        escaped=$(tinyproxy_escape_host "$host") || return 1
        printf '^%s$\n\\.%s$\n' "$escaped" "$escaped" || return 1
    done
}

print_tinyproxy_conf() {
    cat "$SCRIPT_DIR/container/tinyproxy/tinyproxy.conf" || return 1
    printf '\n# Rendered at launch: only the internal jailbox network may use the proxy.\nAllow %s\n' "$1"
}

validate_proxy_configuration() {
    local subnet template expected_filter expected_conf
    local effective=()
    effective_egress_allowlist effective || return 1
    subnet=$(podman network inspect "${NETWORK_NAME}-internal" --format '{{(index .Subnets 0).Subnet}}') || die 'could not inspect proxy subnet'
    if ! validate_ssh_file "${NETWORK_STATE[filter_file]}" 644 file ||
        ! validate_ssh_file "${NETWORK_STATE[proxy_conf_file]}" 644 file; then
        refuse_sandbox 'unsafe proxy configuration files'
    fi
    expected_filter=$(print_tinyproxy_filter "${effective[@]}" && printf '.') || die 'could not render expected proxy filter'
    expected_conf=$(print_tinyproxy_conf "$subnet" && printf '.') || die 'could not read or render expected proxy configuration'
    if ! cmp -s "${NETWORK_STATE[filter_file]}" <(printf '%s' "${expected_filter%.}") ||
        ! cmp -s "${NETWORK_STATE[proxy_conf_file]}" <(printf '%s' "${expected_conf%.}"); then
        refuse_sandbox 'proxy configuration differs from requested policy'
    fi
    require_container_mount "$PROXY_NAME" /etc/tinyproxy/filter bind "${NETWORK_STATE[filter_file]}" false
    require_container_mount "$PROXY_NAME" /etc/tinyproxy/tinyproxy.conf bind "${NETWORK_STATE[proxy_conf_file]}" false
    template='{{range .Mounts}}{{if not (or (eq .Destination "/etc/tinyproxy/filter") (eq .Destination "/etc/tinyproxy/tinyproxy.conf"))}}invalid{{end}}{{end}}true'
    require_container_property "$PROXY_NAME" "$template" 'proxy mount inventory'
    require_container_property "$PROXY_NAME" '{{and (eq .Config.User "tinyproxy") (eq (len .HostConfig.PortBindings) 0)}}' 'proxy user/port policy'
}

start_proxy_container() {
    local internal_net="$1" external_net="$2" proxy_internal_ip="$3"
    echo "🔒 Starting egress proxy ($4 allowed hosts)..."
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
        "$PROXY_IMAGE" || return 1
}
