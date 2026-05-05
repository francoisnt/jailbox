# Post-start checks for basic functionality and containment regressions.

post_start_validation() {
    echo "🔍 Verifying container..."
    WARNINGS=0

    check_authorized_keys
    check_project_write_access
    check_runtime_sockets_absent
    spot_check_readonly_mount

    [ "$WARNINGS" -eq 0 ] && echo "  ✅ All checks passed"
}

check_authorized_keys() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -f /home/devuser/.ssh/authorized_keys" 2>/dev/null; then
        echo "  ⚠️  authorized_keys missing at /home/devuser/.ssh/authorized_keys"
        WARNINGS=$((WARNINGS + 1))
    fi
}

check_project_write_access() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" "test -w '$REMOTE_PATH'" 2>/dev/null; then
        echo "  ⚠️  devuser cannot write to $REMOTE_PATH"
        echo "     Likely cause: UID mismatch. Host UID is $MY_UID."
        echo "     Fix: ensure devuser in the project image has UID $MY_UID, or run with --clean and rebuild."
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

spot_check_readonly_mount() {
    local ro_path
    for ro_path in "${READONLY_PATHS[@]}"; do
        if [ -f "$PROJECT_DIR/$ro_path" ]; then
            if ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" \
                "{ echo x >> '$REMOTE_PATH/$ro_path'; } 2>/dev/null && echo writable || true" \
                2>/dev/null | grep -q "^writable"; then
                echo "  ⚠️  Read-only mount appears writable: $ro_path"
                WARNINGS=$((WARNINGS + 1))
            fi
            break
        fi
    done
}
