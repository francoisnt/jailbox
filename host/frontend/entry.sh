# File-driven public workflows; all machine work runs in child processes.
# shellcheck source=host/frontend/file-policy.sh
source "$SCRIPT_DIR/host/frontend/file-policy.sh"
# shellcheck source=host/frontend/init.sh
source "$SCRIPT_DIR/host/frontend/init.sh"

run_launch() {
    # shellcheck source=host/frontend/editor.sh
    source "$SCRIPT_DIR/host/frontend/editor.sh"
    launch_file_editor "$SCRIPT_DIR/jailbox" "$PROJECT_DIR" "$CONFIG_PATH_ARG"
}

run_headless() {
    load_file_policy "$PROJECT_DIR" "$CONFIG_PATH_ARG" || return $?
    # shellcheck disable=SC2119 # Headless launch contributes no editor hosts.
    compose_machine_environment || return $?
    run_core_command "$SCRIPT_DIR/jailbox" up
}

run_init() {
    init_project_config "$PROJECT_DIR"
}

run_validate() {
    validate_file_config "$SCRIPT_DIR/jailbox" "$PROJECT_DIR" "$CONFIG_PATH_ARG"
}
