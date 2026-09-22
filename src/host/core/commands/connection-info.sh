# commands — connection info

run_connection_info() {
    load_environment_config || return 1
    # Validation diagnostics cannot contaminate the record stream.
    validate_attachment >&2 || return 1
    printf 'ssh_config\t%s\0ssh_host\t%s\0remote_path\t%s\0project_id\t%s\0proxy_url\t%s\0' \
        "$SSH_CONFIG" "$CONTAINER_NAME" "$REMOTE_PATH" "$PROJECT_HASH" "${NETWORK_STATE[proxy_url]}"
}
