# commands — config schema

# Machine schema output; no runtime initialization required.
run_config_schema() {
    local key

    validate_public_api_declaration
    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        printf '%s\tscalar\n' "$key"
    done
    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        printf '%s\tarray\n' "$key"
    done
}
