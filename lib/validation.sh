# Post-start checks for basic functionality and containment regressions.

post_start_validation() {
    echo "🔍 Verifying container..."
    WARNINGS=0

    check_authorized_keys
    check_project_write_access
    check_runtime_sockets_absent
    check_readonly_mounts
    validate_egress_policy

    [ "$WARNINGS" -eq 0 ] && echo "  ✅ All checks passed"
}

check_authorized_keys() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -f /home/$DEV_USER/.ssh/authorized_keys" 2>/dev/null; then
        echo "  ⚠️  authorized_keys missing at /home/$DEV_USER/.ssh/authorized_keys"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_project_write_access() {
    local qpath
    printf -v qpath '%q' "$REMOTE_PATH"
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -w $qpath" 2>/dev/null; then
        echo "  ⚠️  $DEV_USER cannot write to $REMOTE_PATH"
        echo "     Likely cause: UID mismatch. Host UID is $MY_UID."
        echo "     Fix: ensure $DEV_USER in the project image has UID $MY_UID, or run with --clean and rebuild."
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_runtime_sockets_absent() {
    local socket
    for socket in /var/run/docker.sock /run/podman/podman.sock; do
        if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -S '$socket'" 2>/dev/null; then
            echo "  ⚠️  Container runtime socket found at $socket — this is a security risk"
            WARNINGS=$((WARNINGS + 1))
        fi
    done
}

check_readonly_mounts() {
    local ro_path checked failed qpath qro
    checked=0
    failed=0
    printf -v qpath '%q' "$REMOTE_PATH"

    for ro_path in "${READONLY_PATHS[@]}"; do
        if [ -f "$PROJECT_DIR/$ro_path" ]; then
            checked=$((checked + 1))
            printf -v qro '%q' "$ro_path"
            if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
                "{ echo x >> $qpath/$qro; } 2>/dev/null && echo writable || true" \
                2>/dev/null | grep -q "^writable"; then
                echo "  ⚠️  Read-only mount appears writable: $ro_path"
                failed=$((failed + 1))
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        echo "  ⚠️  No file read-only mounts were available to validate"
        WARNINGS=$((WARNINGS + 1))
    elif [ "$failed" -eq 0 ]; then
        echo "  ✅ Read-only mounts validated ($checked files checked)"
    else
        WARNINGS=$((WARNINGS + failed))
    fi
}

validate_egress_policy() {
    if [ "${#EGRESS_ALLOW[@]}" -eq 0 ]; then
        return 0
    fi

    check_internal_network_flag
    check_direct_egress_blocked
    check_proxy_egress_allowed
}

check_internal_network_flag() {
    local internal_value

    internal_value=$(podman network inspect "$JAILBOX_INTERNAL_NETWORK" --format '{{.Internal}}' 2>/dev/null || true)
    if [ "$internal_value" != "true" ]; then
        echo "  ⚠️  Egress network is not marked internal: $JAILBOX_INTERNAL_NETWORK"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_direct_egress_blocked() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "command -v curl >/dev/null 2>&1" 2>/dev/null; then
        echo "  ⚠️  Cannot validate direct egress blocking: curl is not available in jailbox"
        WARNINGS=$((WARNINGS + 1))
        return 0
    fi

    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
        "env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy curl -fsS --connect-timeout 3 --max-time 5 https://example.com >/dev/null" \
        2>/dev/null; then
        echo "  ⚠️  Direct egress succeeded without proxy env — egress policy is not enforced"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "  ✅ Direct egress without proxy is blocked"
    fi
}

check_proxy_egress_allowed() {
    local validation_url

    validation_url=$(egress_validation_url)
    if [ -z "$validation_url" ]; then
        echo "  ⚠️  Skipping proxy egress success check: no HTTP(S)-compatible validation host found in EGRESS_ALLOW"
        WARNINGS=$((WARNINGS + 1))
        return 0
    fi

    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
        "curl -fsS --connect-timeout 5 --max-time 10 '$validation_url' >/dev/null" \
        2>/dev/null; then
        echo "  ✅ Proxy egress succeeded via $validation_url"
    else
        echo "  ⚠️  Proxy egress failed via $validation_url"
        WARNINGS=$((WARNINGS + 1))
    fi
}

egress_validation_url() {
    local domain

    for domain in "${EGRESS_ALLOW[@]}"; do
        case "$domain" in
            ""|*[\(\)\*\+\?\|\[\]\{\}]*|*"'"*|*\"*)
                continue
                ;;
        esac
        printf 'https://%s\n' "$domain"
        return 0
    done

    return 0
}
