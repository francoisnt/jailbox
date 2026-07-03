# SSH key/config generation and readiness waiting.

setup_ssh_keys() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    # Recreate the backing directory on each launch. OpenSSH StrictModes
    # rejects AuthorizedKeysFile paths below world-writable parents, and Podman
    # tmpfs mounts are root-owned here, so this user-owned bind mount gives
    # /run/jailbox-sshd strict permissions without requiring capabilities.
    rm -rf "$SSHD_RUNTIME_DIR"
    mkdir -p "$SSHD_RUNTIME_DIR"
    chmod 700 "$SSHD_RUNTIME_DIR"
    touch "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    # Fresh key pair on every run.
    rm -f "$KEY_FILE" "$KEY_FILE.pub"
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -q
    chmod 600 "$KEY_FILE"
    chmod 644 "$KEY_FILE.pub"

    write_ssh_host_block > "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

ssh_config_quote() {
    local value

    value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

write_ssh_host_block() {
    local env_pair setenv_line
    setenv_line=""

    cat <<SSHEOF
Host $CONTAINER_NAME
    HostName localhost
    Port $LOCAL_PORT
    User $MANAGED_USER
    IdentityFile $(ssh_config_quote "$KEY_FILE")
    IdentitiesOnly yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    StrictHostKeyChecking yes
    UserKnownHostsFile $(ssh_config_quote "$KNOWN_HOSTS")
    BatchMode yes
SSHEOF

    for env_pair in "${SSH_SESSION_ENV[@]}"; do
        setenv_line="${setenv_line:+$setenv_line }$env_pair"
    done
    if [ -n "$setenv_line" ]; then
        # All proxy vars on one SetEnv line. OpenSSH processes only the first
        # SetEnv directive per Host block; multiple SetEnv lines silently drop
        # all but the first. Space-separated vars on one directive is the
        # only portable form. sshd creates fresh session environments, so
        # client-side SetEnv is the reliable way to expose proxy settings to
        # editor terminals and tools.
        printf '    SetEnv %s\n' "$setenv_line"
    fi
}

print_ssh_config_instructions() {
    cat <<EOF_INSTRUCTIONS
SSH config path:
  $SSH_CONFIG

Host alias:
  $CONTAINER_NAME

Manual ~/.ssh/config include:
  Include $SSH_CONFIG

VS Code/VSCodium setting:
  remote.SSH.configFile = $SSH_CONFIG

Host block:
EOF_INSTRUCTIONS
    write_ssh_host_block
}

wait_for_ssh() {
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
        podman logs "$CONTAINER_NAME" >&2 || true
        exit 1
    fi
}

pin_ssh_host_key() {
    local host_key_file host_key

    host_key_file="$SSHD_RUNTIME_DIR/ssh_host_ed25519_key.pub"
    echo "🔐 Pinning SSH host key..."
    for _ in $(seq 1 30); do
        if [ -s "$host_key_file" ]; then
            host_key=$(cat "$host_key_file")
            write_known_host_entry "$host_key"
            return 0
        fi
        sleep 1
    done

    echo "Error: sshd host key was not generated in time: $host_key_file" >&2
    echo "  podman logs $CONTAINER_NAME" >&2
    podman logs "$CONTAINER_NAME" >&2 || true
    exit 1
}

write_known_host_entry() {
    local host_key

    host_key="$1"
    mkdir -p "$(dirname "$KNOWN_HOSTS")"
    ssh-keygen -f "$KNOWN_HOSTS" -R "[localhost]:$LOCAL_PORT" >/dev/null 2>&1 || true
    printf '[localhost]:%s %s\n' "$LOCAL_PORT" "$host_key" >> "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"
}
