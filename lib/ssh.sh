# SSH key/config generation and readiness waiting.

setup_ssh_keys() {
    SSH_DIR="$PROJECT_DIR/.ssh"
    SSH_CONFIG="$SSH_DIR/config"
    KNOWN_HOSTS="$SSH_DIR/known_hosts"
    KEY_FILE="$SSH_DIR/jailbox_key"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    # Fresh key pair on every run.
    rm -f "$KEY_FILE" "$KEY_FILE.pub"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q

    cat > "$SSH_CONFIG" <<SSHEOF
Host $CONTAINER_NAME
    HostName localhost
    Port $LOCAL_PORT
    User $DEV_USER
    IdentityFile $KEY_FILE
    StrictHostKeyChecking no
    UserKnownHostsFile $KNOWN_HOSTS
    BatchMode yes
SSHEOF
    chmod 600 "$SSH_CONFIG"
}

wait_for_ssh() {
    ssh-keygen -f "$KNOWN_HOSTS" -R "[localhost]:$LOCAL_PORT" 2>/dev/null || true

    echo "⏳ Waiting for sshd..."
    SSH_READY=false
    for i in $(seq 1 30); do
        if ssh -F "$SSH_CONFIG" -o ConnectTimeout=1 "$CONTAINER_NAME" true 2>/dev/null; then
            echo "✅ SSH is up (attempt $i)"
            SSH_READY=true
            break
        fi
        sleep 1
    done

    if [ "$SSH_READY" = false ]; then
        echo "Error: sshd did not become ready in time. Check container logs:" >&2
        echo "  podman logs $CONTAINER_NAME"
        exit 1
    fi
}
