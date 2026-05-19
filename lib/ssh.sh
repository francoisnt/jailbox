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

    # Register the project SSH config in ~/.ssh/config so VS Code Remote SSH
    # can resolve the container host. Include must appear before any Host block,
    # so prepend it if not already present.
    local global_config="$HOME/.ssh/config"
    local include_line="Include $SSH_CONFIG"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$global_config"
    chmod 600 "$global_config"
    if ! grep -qxF "$include_line" "$global_config" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        { printf '%s\n' "$include_line"; cat "$global_config"; } > "$tmp"
        mv "$tmp" "$global_config"
        chmod 600 "$global_config"
    fi
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
