# commands — validate

run_validate() {
    require_command realpath
    load_environment_config || return 1
    validate_project_boundary || return 1
    validate_configured_readonly_paths || return 1
    validate_local_build_inputs || return 1
    finalize_effective_readonly_paths || return 1
    printf 'Configuration and local launch inputs are valid; sandbox health and build success were not checked.\n'
}
