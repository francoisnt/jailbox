# Editor launch and generated Remote SSH profile config.

JAILBOX_EDITOR_USER_DATA=""
JAILBOX_EDITOR_USER_SETTINGS=""

initialize_editor_state() {
    [[ -n "$PROJECT_STATE_ROOT" && -n "$PROJECT_HASH" ]] || \
        die "internal error: editor state requires initialized project state"
    JAILBOX_EDITOR_USER_DATA="$PROJECT_STATE_ROOT/editor-profiles/$PROJECT_HASH"
    JAILBOX_EDITOR_USER_SETTINGS="$JAILBOX_EDITOR_USER_DATA/User/settings.json"
}

assert_editor_state_initialized() {
    [[ -n "$JAILBOX_EDITOR_USER_DATA" && -n "$JAILBOX_EDITOR_USER_SETTINGS" ]] || \
        die "internal error: editor state is not initialized"
}

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
    write_jailbox_editor_user_settings || return 1
    write_remote_editor_smoke_settings
    "$EDITOR_BIN" --user-data-dir "$JAILBOX_EDITOR_USER_DATA" \
        --remote "ssh-remote+$CONTAINER_NAME" "$REMOTE_PATH"
}

# Standalone JSON object with smoke test settings — single source of truth.
editor_smoke_settings_json_object() {
    printf '{\n'
    printf '  "security.workspace.trust.enabled": false,\n'
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        printf '  "http.proxy": "%s",\n' "${NETWORK_STATE[proxy_url]}"
    fi
    printf '  "task.allowAutomaticTasks": "on"\n'
    printf '}'
}

editor_smoke_profile_settings_json() {
    [ "${JAILBOX_EDITOR_SMOKE_TEST_SETTINGS:-}" = "1" ] || return 0

    printf ',\n'
    editor_smoke_settings_json_object | sed '1d; $d'
}

# Pre-populate the remote server's Machine settings so task.allowAutomaticTasks
# is in effect before the extension host starts. Without this, the remote host
# falls back to the default "prompt" value and folderOpen tasks never fire.
write_remote_editor_smoke_settings() {
    [ "${JAILBOX_EDITOR_SMOKE_TEST_SETTINGS:-}" = "1" ] || return 0

    editor_smoke_settings_json_object | ssh -F "$SSH_CONFIG" "$CONTAINER_NAME" /usr/local/bin/jailbox-write-editor-settings
}

editor_config_has_ssh_config() {
    local config_file

    config_file="$1"
    [ -f "$config_file" ] || return 1
    grep -Fq "\"remote.SSH.configFile\": \"$SSH_CONFIG\"" "$config_file"
}

editor_profile_uses_code() {
    local requested_editor

    requested_editor="${JAILBOX_EDITOR:-$EDITOR}"
    if [ "$requested_editor" = "code" ]; then
        return 0
    fi
    if [ -n "$EDITOR_BIN" ]; then
        [ "$(basename "$EDITOR_BIN")" = "code" ]
        return $?
    fi
    [ -z "$requested_editor" ] && ! command -v codium >/dev/null 2>&1 && command -v code >/dev/null 2>&1
}

write_jailbox_editor_user_settings() (
    # Keep staging cleanup and signal traps separate from the caller's scope.
    local settings_dir settings_tmp="" smoke_settings
    cleanup_editor_settings() {
        local status=$?
        if [ -n "$settings_tmp" ]; then
            rm -f -- "$settings_tmp" || { echo "Error: could not clean temporary editor settings: $settings_tmp" >&2; [ "$status" -ne 0 ] || status=1; }
        fi
        exit "$status"
    }
    trap cleanup_editor_settings EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    assert_editor_state_initialized || return 1

    settings_dir="$(dirname "$JAILBOX_EDITOR_USER_SETTINGS")" || return 1
    mkdir -p "$settings_dir" || return 1
    settings_tmp=$(mktemp "$settings_dir/settings.json.tmp.XXXXXX") || return 1
    smoke_settings=$(editor_smoke_profile_settings_json) || return 1
    if [ -n "${EGRESS_ALLOW[*]-}" ]; then
        cat > "$settings_tmp" <<EOF_SETTINGS || return 1
{
  "remote.SSH.configFile": "$SSH_CONFIG"$smoke_settings,
  "http.proxy": "${NETWORK_STATE[proxy_url]}",
  "terminal.integrated.env.linux": {
    "HTTP_PROXY": "${NETWORK_STATE[proxy_url]}",
    "HTTPS_PROXY": "${NETWORK_STATE[proxy_url]}",
    "http_proxy": "${NETWORK_STATE[proxy_url]}",
    "https_proxy": "${NETWORK_STATE[proxy_url]}",
    "NO_PROXY": "${NETWORK_STATE[no_proxy]}",
    "no_proxy": "${NETWORK_STATE[no_proxy]}"
  }
}
EOF_SETTINGS
    else
        cat > "$settings_tmp" <<EOF_SETTINGS || return 1
{
  "remote.SSH.configFile": "$SSH_CONFIG"$smoke_settings
}
EOF_SETTINGS
    fi
    chmod 600 "$settings_tmp" || return 1
    mv "$settings_tmp" "$JAILBOX_EDITOR_USER_SETTINGS" || return 1
    settings_tmp=""
)
