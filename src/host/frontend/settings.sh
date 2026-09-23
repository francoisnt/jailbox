# shellcheck disable=SC2030,SC2031 # Cleanup reads locals in the owning subshell.
# JSON for the generated editor settings object. Keep this small
# schema local; unrelated editor settings are not a frontend input contract.

valid_settings_text() {
    local value=$1 LC_ALL=C continuation=$'[\x80-\xbf]'
    # JSON requires Unicode. Reject malformed UTF-8, overlong sequences,
    # surrogates, controls, and code points outside Unicode before publication.
    local utf8
    utf8=$'[\x20-\x7e]|[\xc2-\xdf]'"$continuation"
    utf8+=$'|\xe0[\xa0-\xbf]'"$continuation"$'|[\xe1-\xec\xee-\xef]'"$continuation$continuation"
    utf8+=$'|\xed[\x80-\x9f]'"$continuation"$'|\xf0[\x90-\xbf]'"$continuation$continuation"
    utf8+=$'|[\xf1-\xf3]'"$continuation$continuation$continuation"$'|\xf4[\x80-\x8f]'"$continuation$continuation"
    [[ "$value" =~ ^($utf8)*$ ]]
}

json_string() {
    local value=$1
    valid_settings_text "$value" || { printf 'Error: editor settings require control-free UTF-8 text\n' >&2; return 1; }
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

render_editor_settings() {
    local config_json proxy_json proxy_line=""
    config_json=$(json_string "${EDITOR_CONNECTION[ssh_config]}") || return 1
    if [[ -n ${EDITOR_CONNECTION[proxy_url]} ]]; then
        proxy_json=$(json_string "${EDITOR_CONNECTION[proxy_url]}") || return 1
        proxy_line=$',\n  "http.proxy": '"$proxy_json"
    fi
    # Cat is intentionally a checked producer, as in the existing writer.
    cat <<EOF_SETTINGS
{
  "remote.SSH.enableAgentForwarding": false,
  "remote.SSH.configFile": $config_json$proxy_line
}
EOF_SETTINGS
}

cleanup_editor_settings() {
    local status=$?
    if [[ -n "$settings_tmp" ]] && ! rm -f -- "$settings_tmp"; then
        printf 'Error: could not clean temporary editor settings: %s\n' "$settings_tmp" >&2
        [[ "$status" != 0 ]] || status=1
    fi
    exit "$status"
}

write_editor_settings() (
    local settings_file=$1 settings_dir settings_tmp=""
    trap cleanup_editor_settings EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    settings_dir=$(dirname -- "$settings_file") || return 1
    mkdir -p -- "$settings_dir" || return 1
    [[ ! -L "$settings_file" && ! -d "$settings_file" ]] || return 1
    settings_tmp=$(mktemp "$settings_dir/settings.json.tmp.XXXXXX") || return 1
    render_editor_settings > "$settings_tmp" || return 1
    chmod 600 "$settings_tmp" || return 1
    mv -f -- "$settings_tmp" "$settings_file" || return 1
    settings_tmp=""
)
