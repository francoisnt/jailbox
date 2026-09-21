# Read-only required readiness checks. Up alone synchronizes managed home blocks;
# attachment can reuse these checks without builds or lifecycle mutation.

validation_ssh() {
    ssh -F "$SSH_CONFIG" -o ConnectTimeout=3 -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=2 "$CONTAINER_NAME" "$@"
}

validate_existing_sandbox_health() {
    if [ "$UP_DEV_STATE" = running ]; then
        validate_running_development
    fi
    if [ "$UP_PROXY_STATE" = running ]; then
        validate_proxy_ready
    fi
    if [ "$UP_DEV_STATE" = running ] && [ "$UP_PROXY_STATE" = running ]; then
        check_proxy_egress_denied
    fi
}

validate_running_development() {
    validate_development_session full
}

post_start_validation() {
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        check_downloader_proxy_config
        check_proxy_egress_denied
        check_proxy_egress_allowed
    else
        check_downloader_proxy_config_absent
    fi
    echo '✅ Sandbox is ready'
}

check_readonly_mounts() {
    validate_development_session mounts
}

validate_development_session() {
    local mode="$1" path arguments result proxy="" index payload status=0
    local -a paths=(/)
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do paths+=("$REMOTE_PATH/$path"); done
    if [[ "$mode" = full && -n "${EGRESS_ALLOW[*]-}" ]]; then proxy=${NETWORK_STATE[proxy_url]}; fi
    if [[ ! -f "$SCRIPT_DIR/container/checks/validate-session.sh" ]] ||
        ! payload=$(< "$SCRIPT_DIR/container/checks/validate-session.sh"); then
        refuse_local_validation 'could not read local validation payload; repair the jailbox installation before retrying'
        return 1
    fi
    printf -v arguments "%q " "$mode" "$REMOTE_PATH" "$proxy" "${paths[@]}"
    result=$(validation_ssh "bash -s -- $arguments" <<< "$payload" && printf '.') || status=$?
    if [[ "$status" != 0 ]]; then
        refuse_sandbox "SSH validation command failed (exit $status; transport or remote execution error)"
        return 1
    fi
    case "$result" in
        $'ok\n.') return 0 ;;
        $'authorized-keys\n.') refuse_sandbox 'authorized_keys is unavailable' ;;
        $'project-write\n.') refuse_local_validation 'managed user cannot write the project; correct host project ownership and permissions before retrying' ;;
        $'sockets\n.') refuse_sandbox 'runtime socket isolation could not be established' ;;
        $'hardening\n.') refuse_sandbox 'live process hardening could not be established' ;;
        $'proxy-env\n.') refuse_sandbox 'live SSH proxy settings differ from policy' ;;
        $'direct-route\n.') refuse_sandbox 'direct-route isolation could not be established' ;;
        *)
            for index in "${!paths[@]}"; do
                if [[ "$result" = "mount:$index"$'\n.' ]]; then
                    refuse_sandbox "read-only mount '${paths[index]}' could not be established"
                    return 1
                fi
            done
            refuse_sandbox 'invalid SSH validation response: expected one result; check shell startup files for unexpected output' ;;
    esac
    return 1
}

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

check_downloader_proxy_config() {
    validation_ssh "jailbox-manage-proxy check-enable $(printf '%q' "${NETWORK_STATE[proxy_url]}")" || refuse_downloader_sync "managed downloader settings are not synchronized"
}

check_downloader_proxy_config_absent() {
    validation_ssh 'jailbox-manage-proxy check-disable' || refuse_downloader_sync "stale managed downloader settings remain"
}

# One read-only attachment boundary, shared by all transport consumers.
validate_attachment() {
    require_command podman || return 1
    require_command ssh || return 1
    require_command ssh-keygen || return 1
    require_command realpath || return 1
    initialize_project_names || return 1
    initialize_config_digest_state || return 1
    initialize_dev_image_state || return 1
    initialize_ssh_state || return 1
    initialize_network_state || return 1
    initialize_container_runtime_state || return 1
    initialize_runtime_ids || return 1
    validate_ssh_state_path || return 1
    validate_configured_readonly_paths || return 1
    require_compatible_home || return 1
    compute_config_digest attach || return 1
    require_compatible_project_resources attach || return 1
    inspect_sandbox_for_up attach || return 1
    [ "$UP_DEV_STATE" = running ] || die "development sandbox is $UP_DEV_STATE; run 'jailbox up' before attaching"
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        [ "$UP_PROXY_STATE" = running ] || die "proxy is $UP_PROXY_STATE; run 'jailbox up' before attaching"
    fi
    validate_running_development || return 1
    validate_proxy_ready || return 1
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        check_proxy_egress_denied || return 1
        check_downloader_proxy_config || return 1
    else
        check_downloader_proxy_config_absent || return 1
    fi
}

run_connection_info() {
    load_environment_config || return 1
    # Validation diagnostics cannot contaminate the record stream.
    validate_attachment >&2 || return 1
    printf 'ssh_config\t%s\0ssh_host\t%s\0remote_path\t%s\0project_id\t%s\0proxy_url\t%s\0' \
        "$SSH_CONFIG" "$CONTAINER_NAME" "$REMOTE_PATH" "$PROJECT_HASH" "${NETWORK_STATE[proxy_url]}"
}

refuse_local_validation() {
    if [ "$UP_CONVERGING" = true ]; then fail_sandbox_readiness "$@"; fi
    die "$*"
}

refuse_downloader_sync() {
    if [ "$UP_CONVERGING" = true ]; then fail_sandbox_readiness "$@"; fi
    die "$*; run 'jailbox up' before attaching"
}
