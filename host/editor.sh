# Editor launch and generated Remote SSH profile config.

open_editor() {
    if ! ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" true 2>/dev/null; then
        echo "Error: jailbox could not verify SSH before opening the editor." >&2
        echo "SSH config: $SSH_CONFIG" >&2
        echo "Host alias: $CONTAINER_NAME" >&2
        return 1
    fi

    echo "🚀 Connecting..."
    launch_editor_remote
}

launch_editor_remote() {
    write_jailbox_editor_user_settings
    "$EDITOR_BIN" --user-data-dir "$JAILBOX_EDITOR_USER_DATA" \
        --remote "ssh-remote+$CONTAINER_NAME" "$REMOTE_PATH"
}

editor_config_has_ssh_config() {
    local config_file

    config_file="$1"
    [ -f "$config_file" ] || return 1
    grep -Fq "\"remote.SSH.configFile\": \"$SSH_CONFIG\"" "$config_file"
}

write_jailbox_editor_user_settings() {
    mkdir -p "$(dirname "$JAILBOX_EDITOR_USER_SETTINGS")"
    if [ "${#EGRESS_ALLOW[@]}" -gt 0 ]; then
        cat > "$JAILBOX_EDITOR_USER_SETTINGS" <<EOF_SETTINGS
{
  "remote.SSH.configFile": "$SSH_CONFIG",
  "terminal.integrated.env.linux": {
    "HTTP_PROXY": "$PROXY_URL",
    "HTTPS_PROXY": "$PROXY_URL",
    "http_proxy": "$PROXY_URL",
    "https_proxy": "$PROXY_URL",
    "NO_PROXY": "$PROXY_NO_PROXY",
    "no_proxy": "$PROXY_NO_PROXY"
  }
}
EOF_SETTINGS
    else
        cat > "$JAILBOX_EDITOR_USER_SETTINGS" <<EOF_SETTINGS
{
  "remote.SSH.configFile": "$SSH_CONFIG"
}
EOF_SETTINGS
    fi
    chmod 600 "$JAILBOX_EDITOR_USER_SETTINGS"
}
