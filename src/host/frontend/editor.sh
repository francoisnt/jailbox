# shellcheck disable=SC2030,SC2031 # Cleanup reads locals in the owning subshell.
# Editor client. The caller loads file-policy.sh.
EDITOR_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=src/host/frontend/connection.sh
source "$EDITOR_MODULE_DIR/connection.sh"
# shellcheck source=src/host/frontend/settings.sh
source "$EDITOR_MODULE_DIR/settings.sh"

EDITOR_NAME=""
EDITOR_BIN=""
EDITOR_EXTENSIONS_DIR=""
EDITOR_BOOTSTRAP_HOSTS=()

warn_low_inotify_watch_limit() {
    local limit_file limit recommended

    recommended=524288
    limit_file="${JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE:-/proc/sys/fs/inotify/max_user_watches}"
    [ -r "$limit_file" ] || return 0

    limit=$(cat "$limit_file" 2>/dev/null || true)
    [[ "$limit" =~ ^[0-9]+$ ]] || return 0
    [ "$limit" -ge "$recommended" ] && return 0

    echo "⚠️  fs.inotify.max_user_watches is $limit; VSCodium/VS Code Remote SSH may be unable to watch workspace file changes." >&2
    echo "   Fix on the Linux host: echo 'fs.inotify.max_user_watches=$recommended' | sudo tee /etc/sysctl.d/60-jailbox-inotify.conf && sudo sysctl --system" >&2
}

editor_preflight() {
    local requested=${FRONTEND_VALUES[EDITOR]-} selection inventory extension line found=0
    local state_home=${XDG_STATE_HOME:-${HOME:-}/.local/state}
    local -a errors=()
    EDITOR_NAME=""
    EDITOR_BIN=""
    EDITOR_EXTENSIONS_DIR=""
    EDITOR_BOOTSTRAP_HOSTS=()
    if [[ -n "$requested" ]]; then
        selection="file EDITOR=$requested"
        case "$requested" in
            code|codium) EDITOR_NAME=$requested ;;
            *) printf 'Error: %s; resolved editor: none; expected code or codium\n' "$selection" >&2; return 1 ;;
        esac
        EDITOR_BIN=$(command -v "$EDITOR_NAME") || EDITOR_BIN=""
    else
        selection='automatic discovery (codium, then code)'
        for EDITOR_NAME in codium code; do
            EDITOR_BIN=$(command -v "$EDITOR_NAME") && break
        done
        if [[ -z "$EDITOR_BIN" ]]; then
            printf 'Error: %s; resolved editor: none; missing binaries: codium, code; Remote SSH inventory cannot be checked\n' "$selection" >&2
            return 1
        fi
    fi
    case "$EDITOR_NAME" in
        codium)
            extension=jeanp413.open-remote-ssh
            EDITOR_EXTENSIONS_DIR=${HOME:-}/.vscode-oss/extensions
            EDITOR_BOOTSTRAP_HOSTS=(github.com githubusercontent.com)
            ;;
        code)
            extension=ms-vscode-remote.remote-ssh
            EDITOR_EXTENSIONS_DIR=${HOME:-}/.vscode/extensions
            EDITOR_BOOTSTRAP_HOSTS=(update.code.visualstudio.com vscode.download.prss.microsoft.com main.vscode-cdn.net vo.msecnd.net)
            ;;
    esac
    if [[ "${HOME:-}" != /* ]] || ! valid_settings_text "${HOME:-}"; then
        errors+=('profile home must be an absolute, control-free UTF-8 path')
    fi
    if [[ "$state_home" != /* ]] || ! valid_settings_text "$state_home"; then
        errors+=('profile state home must be an absolute, control-free UTF-8 path')
    fi
    if [[ -z "$EDITOR_BIN" ]]; then
        errors+=("missing executable $EDITOR_NAME; cannot check required extension $extension")
    elif ! inventory=$("$EDITOR_BIN" --extensions-dir "$EDITOR_EXTENSIONS_DIR" --list-extensions); then
        errors+=("extension inventory failed; required extension $extension could not be verified")
    else
        while IFS= read -r line; do
            [[ "$line" != "$extension" ]] || found=1
        done <<< "$inventory"
        [[ "$found" == 1 ]] || errors+=("missing required extension $extension in $EDITOR_EXTENSIONS_DIR")
    fi
    if [[ -n "${errors[*]-}" ]]; then
        printf 'Error: %s; resolved editor: %s\n' "$selection" "${EDITOR_BIN:-$EDITOR_NAME (not found)}" >&2
        printf '  %s\n' "${errors[@]}" >&2
        return 1
    fi
}

launch_editor_remote() {
    local profile settings state_home=${XDG_STATE_HOME:-$HOME/.local/state}
    [[ -n "$EDITOR_BIN" && -n "${EDITOR_CONNECTION[project_id]-}" ]] || return 1
    if [[ "$HOME" != /* ]] || ! valid_settings_text "$HOME"; then
        printf 'Error: invalid editor profile home\n' >&2
        return 1
    fi
    [[ "$state_home" = /* ]] && valid_settings_text "$state_home" || return 1
    profile=$state_home/jailbox/editor-profiles/${EDITOR_CONNECTION[project_id]}
    settings=$profile/User/settings.json
    write_editor_settings "$settings" || { printf 'Error: could not publish editor settings\n' >&2; return 1; }
    "$EDITOR_BIN" --extensions-dir "$EDITOR_EXTENSIONS_DIR" --user-data-dir "$profile" \
        --remote "ssh-remote+${EDITOR_CONNECTION[ssh_host]}" "${EDITOR_CONNECTION[remote_path]}"
}

cleanup_connection_output() {
    local status=$?
    if [[ -n "$connection_file" ]] && ! rm -f -- "$connection_file"; then
        printf 'Error: could not clean temporary connection records: %s\n' "$connection_file" >&2
        [[ "$status" != 0 ]] || status=1
    fi
    exit "$status"
}

# The subshell owns staging and editor state without changing caller traps.
launch_file_editor() (
    local executable=$1 project=$2 selected=${3:-} connection_file=""
    trap cleanup_connection_output EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    load_file_policy "$project" "$selected" || return $?
    editor_preflight || return $?
    warn_low_inotify_watch_limit
    compose_machine_environment "${EDITOR_BOOTSTRAP_HOSTS[@]}" || return $?
    run_core_command "$executable" up || return $?
    connection_file=$(mktemp "${TMPDIR:-/tmp}/jailbox-connection.XXXXXX") || return 1
    run_core_command "$executable" connection-info > "$connection_file" || return $?
    parse_connection_records "$connection_file" || return $?
    rm -f -- "$connection_file" || return 1
    connection_file=""
    launch_editor_remote || return $?
)
