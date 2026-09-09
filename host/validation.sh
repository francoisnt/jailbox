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
    validation_ssh true || refuse_sandbox 'pinned SSH authentication failed'
    check_authorized_keys
    check_project_write_access
    check_runtime_sockets_absent
    check_readonly_mounts
    # shellcheck disable=SC2016  # Awk fields are interpreted remotely.
    validation_ssh 'awk '\''
        /^CapEff:/ { caps = ($2 == "0000000000000000"); seen_caps = 1 }
        /^CapBnd:/ { bound = ($2 == "0000000000000000"); seen_bound = 1 }
        /^NoNewPrivs:/ { nnp = ($2 == "1"); seen_nnp = 1 }
        END { exit !(seen_caps && caps && seen_bound && bound && seen_nnp && nnp) }
    '\'' /proc/1/status' || refuse_sandbox 'live process hardening could not be established'
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        check_proxy_env_in_session
        check_direct_egress_blocked
    fi
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

check_authorized_keys() {
    validation_ssh 'test -f /run/jailbox-sshd/authorized_keys' || refuse_sandbox 'authorized_keys is unavailable'
}

check_project_write_access() {
    validation_ssh "test -w $(printf '%q' "$REMOTE_PATH")" || refuse_sandbox 'managed user cannot write the project'
}

check_runtime_sockets_absent() {
    validation_ssh 'test ! -S /var/run/docker.sock && test ! -S /run/podman/podman.sock' || refuse_sandbox 'runtime socket isolation could not be established'
}

# Inspect the mount table for both files and directories, including the root.
# Missing input is a failure, never a skipped check. No writable marker probes.
check_readonly_mounts() {
    local path
    local paths=(/)
    for path in "${EFFECTIVE_READONLY_PATHS[@]}"; do
        paths+=("$REMOTE_PATH/$path")
    done
    for path in "${paths[@]}"; do
        validation_ssh "TARGET=$(printf '%q' "$path") sh -s" <<'REMOTE' || refuse_sandbox "read-only mount '$path' could not be established"
set -eu
# The shell passes the path through the environment, not awk -v (which would
# reinterpret backslashes in a path).
awk '
    BEGIN { target = ENVIRON["TARGET"]; found = 0; invalid = 0 }
    {
        path = $5
        gsub(/\\040/, " ", path)
        gsub(/\\011/, "\t", path)
        gsub(/\\012/, "\n", path)
        gsub(/\\134/, "\\", path)
        if (path != target) next
        found++
        if ($6 !~ /(^|,)ro(,|$)/) invalid = 1
    }
    END { exit !(found == 1 && !invalid) }
' /proc/self/mountinfo
REMOTE
    done
}

check_proxy_env_in_session() {
    validation_ssh "EXPECTED=$(printf '%q' "${NETWORK_STATE[proxy_url]}") bash -s" <<'REMOTE' || refuse_sandbox 'live SSH proxy settings differ from policy'
set -euo pipefail
for name in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    [[ ${!name-} == "$EXPECTED" ]] || exit 1
done
[[ ${NO_PROXY-} == localhost,127.0.0.1 && ${no_proxy-} == localhost,127.0.0.1 ]]
REMOTE
}

check_direct_egress_blocked() {
    # Topology is the isolation evidence. A failed Internet request would also
    # fail on an offline host and therefore cannot prove this property.
    validation_ssh 'sh -s' <<'REMOTE' || refuse_sandbox 'direct-route isolation could not be established'
set -eu
awk 'NR > 1 && $2 == "00000000" { bad = 1 } END { exit bad }' /proc/net/route
if [ -e /proc/net/ipv6_route ]; then
    awk '$1 == "00000000000000000000000000000000" && $2 == "00" && $10 != "lo" { bad = 1 } END { exit bad }' /proc/net/ipv6_route
fi
REMOTE
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
    podman exec "$PROXY_NAME" sh -c '
        export EXPECTED_GATEWAY="$1"
        awk '\''
            BEGIN {
                split(ENVIRON["EXPECTED_GATEWAY"], octets, ".")
                expected = sprintf("%02X%02X%02X%02X", octets[4], octets[3], octets[2], octets[1])
            }
            NR > 1 && $2 == "00000000" { count++; if ($3 != expected) bad = 1 }
            END { exit !(count == 1 && !bad) }
        '\'' /proc/net/route
    ' sh "$gateway" >/dev/null || refuse_sandbox 'proxy external default route is not ready'
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
    validation_ssh "jailbox-manage-proxy check-enable $(printf '%q' "${NETWORK_STATE[proxy_url]}")" || refuse_sandbox 'managed downloader settings are not synchronized'
}

check_downloader_proxy_config_absent() {
    validation_ssh 'jailbox-manage-proxy check-disable' || refuse_sandbox 'stale managed downloader settings remain'
}
