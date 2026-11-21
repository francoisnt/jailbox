# Private helper paths are relative to the CLI in both layouts.
core_tool() {
    local program="$SCRIPT_DIR/libexec/jailbox-core" version
    require_private_program "$program" || return 1
    version=$(jailbox_version) || return 1
    "$program" "$version" "$@"
}

require_private_program() {
    if [[ ! -f "$1" || ! -x "$1" ]]; then
        printf 'Error: jailbox helper is missing or not executable: %s. Build checkout programs with scripts/build-programs.sh or reinstall jailbox.\n' "$1" >&2
        return 1
    fi
}

container_helper_command() {
    local version
    version=$(jailbox_version) || return 1
    printf '/usr/local/lib/jailbox/jailbox-container %s' "$version"
}
