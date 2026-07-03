# Post-start checks for basic functionality and containment regressions.

post_start_validation() {
    echo "🔍 Verifying container..."
    WARNINGS=0

    check_authorized_keys
    check_project_write_access
    check_runtime_sockets_absent
    check_readonly_mounts
    validate_egress_policy

    if [ "$WARNINGS" -eq 0 ]; then
        echo "  ✅ All checks passed"
    fi
}

check_authorized_keys() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -f /run/jailbox-sshd/authorized_keys" 2>/dev/null; then
        echo "  ⚠️  authorized_keys missing at /run/jailbox-sshd/authorized_keys"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_project_write_access() {
    local qpath
    printf -v qpath '%q' "$REMOTE_PATH"
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -w $qpath" 2>/dev/null; then
        echo "  ⚠️  $MANAGED_USER cannot write to $REMOTE_PATH"
        echo "     Likely cause: UID mismatch. Host UID is $MY_UID."
        echo "     Fix: ensure the managed jailbox user can use host UID $MY_UID, or run with --clean and rebuild."
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
    local ro_path checked failed qpath qro marker
    checked=0
    failed=0
    printf -v qpath '%q' "$REMOTE_PATH"
    marker=".jailbox-ro-check-$$"

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
        elif [ -d "$PROJECT_DIR/$ro_path" ]; then
            checked=$((checked + 1))
            printf -v qro '%q' "$ro_path"
            if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
                "REMOTE_PATH=$qpath RO_PATH=$qro MARKER=$(printf '%q' "$marker") bash -s" <<'REMOTE' 2>/dev/null | grep -q "^writable"; then
set -euo pipefail
# The marker source must live on a path that is always writable (/tmp is
# container tmpfs). Sourcing it from the project tree would abort under
# set -e before the copy probe runs whenever that path is itself read-only,
# making the check pass vacuously.
marker_src="/tmp/$MARKER"
marker_target="$REMOTE_PATH/$RO_PATH/$MARKER"
cleanup_marker() {
    rm -f -- "$marker_src" "$marker_target"
}
trap cleanup_marker EXIT

touch -- "$marker_src"
if cp -- "$marker_src" "$marker_target" 2>/dev/null; then
    echo writable
fi
REMOTE
                echo "  ⚠️  Read-only mount appears writable: $ro_path"
                failed=$((failed + 1))
            fi
        fi
    done

    if [ "$checked" -eq 0 ]; then
        echo "  ⚠️  No read-only mounts were available to validate"
        WARNINGS=$((WARNINGS + 1))
    elif [ "$failed" -eq 0 ]; then
        echo "  ✅ Read-only mounts validated ($checked entries checked)"
    else
        WARNINGS=$((WARNINGS + failed))
    fi
}

validate_egress_policy() {
    if [ "${#EGRESS_ALLOW[@]}" -eq 0 ]; then
        check_downloader_proxy_config_absent
        return 0
    fi

    check_internal_network_flag
    check_proxy_env_in_session
    check_downloader_proxy_config
    check_direct_egress_blocked
    check_proxy_egress_allowed
}

check_downloader_proxy_config_absent() {
    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "bash -s" <<'REMOTE' 2>/dev/null
set -euo pipefail
for file in "$HOME/.curlrc" "$HOME/.wgetrc"; do
    if [[ -f "$file" ]] && grep -Fqx "# >>> jailbox managed proxy >>>" "$file"; then
        exit 1
    fi
done
REMOTE
    then
        return 0
    fi

    echo "  ⚠️  Stale downloader proxy config remains in non-egress mode"
    WARNINGS=$((WARNINGS + 1))
}

check_internal_network_flag() {
    local internal_value

    internal_value=$(podman network inspect "$JAILBOX_INTERNAL_NETWORK" --format '{{.Internal}}' 2>/dev/null || true)
    if [ "$internal_value" != "true" ]; then
        echo "  ⚠️  Egress network is not marked internal: $JAILBOX_INTERNAL_NETWORK"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_proxy_env_in_session() {
    local val
    val=$(ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
        "printf '%s' \"\$HTTPS_PROXY\"" 2>/dev/null || true)
    if [ -z "$val" ]; then
        echo "  ⚠️  HTTPS_PROXY is not set in SSH sessions — generated SSH SetEnv may be missing or rejected"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "  ✅ HTTPS_PROXY is set in SSH sessions ($val)"
    fi
}

check_downloader_proxy_config() {
    local proxy_url

    proxy_url="$PROXY_URL"
    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "PROXY_URL='$proxy_url' bash -s" <<'REMOTE' 2>/dev/null
set -euo pipefail

check_block() {
    local file="$1"
    local expected="$2"
    local actual

    actual=$(awk '
        $0 == "# >>> jailbox managed proxy >>>" { in_block = 1; next }
        $0 == "# <<< jailbox managed proxy <<<" { in_block = 0; found = 1; next }
        in_block { block = block $0 "\n" }
        END {
            if (!found) exit 1
            printf "%s", block
        }
    ' "$file")
    [[ "$actual" == "$expected" ]]
}

check_block "$HOME/.curlrc" "proxy = \"$PROXY_URL\""
check_block "$HOME/.wgetrc" "use_proxy = on
http_proxy = $PROXY_URL
https_proxy = $PROXY_URL"
REMOTE
    then
        echo "  ✅ Downloader proxy config is managed"
    else
        echo "  ⚠️  Downloader proxy config is missing or stale"
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
        "env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy curl -q --noproxy '*' -fsS --connect-timeout 3 --max-time 5 https://example.com >/dev/null" \
        2>/dev/null; then
        echo "  ⚠️  Direct egress succeeded without proxy env — egress policy is not enforced"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "  ✅ Direct egress without proxy is blocked"
    fi
}

check_proxy_egress_allowed() {
    local validation_domain

    validation_domain=$(egress_validation_domain)
    if [ -z "$validation_domain" ]; then
        echo "  ⚠️  Skipping proxy egress check: no valid host found in EGRESS_ALLOW"
        WARNINGS=$((WARNINGS + 1))
        return 0
    fi

    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
        "curl -fsS --connect-timeout 5 --max-time 10 'https://$validation_domain' >/dev/null" \
        2>/dev/null; then
        echo "  ✅ Proxy egress to $validation_domain succeeded"
    else
        echo "  ⚠️  Proxy egress to $validation_domain failed"
        WARNINGS=$((WARNINGS + 1))
    fi

    if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
        "if command -v wget >/dev/null 2>&1; then wget -qO- --timeout=10 'https://$validation_domain' >/dev/null; fi" \
        2>/dev/null; then
        :
    else
        echo "  ⚠️  wget proxy egress to $validation_domain failed"
        WARNINGS=$((WARNINGS + 1))
    fi
}

egress_validation_domain() {
    local domain

    for domain in "${EGRESS_ALLOW[@]}"; do
        case "$domain" in
            ""|*[\(\)\*\+\?\|\[\]\{\}]*|*"'"*|*\"*)
                continue
                ;;
        esac
        printf '%s\n' "$domain"
        return 0
    done

    return 0
}
