# SSH key/config generation and readiness waiting.

setup_ssh_keys() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    # Fresh key pair on every run.
    rm -f "$KEY_FILE" "$KEY_FILE.pub"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
    chmod 600 "$KEY_FILE"

    write_ssh_config > "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

write_ssh_config() {
    cat <<SSHEOF
Host $CONTAINER_NAME
    HostName localhost
    Port $LOCAL_PORT
    User $DEV_USER
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    StrictHostKeyChecking no
    UserKnownHostsFile $KNOWN_HOSTS
    BatchMode yes
SSHEOF
}

print_ssh_config_instructions() {
    cat <<EOF_INSTRUCTIONS
SSH config path:
  $SSH_CONFIG

Manual ~/.ssh/config include:
  Include $SSH_CONFIG

Host block:
EOF_INSTRUCTIONS
    write_ssh_config
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
