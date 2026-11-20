# resources — home

# Classify inside the template: arbitrary label bytes (including trailing
# newlines) must never become valid through shell command substitution. An
# absent key, a present empty value, and failed inspection stay distinct.
# Failed inspection exits. Recovery asks for retention only. Launch and
# attachment also need the generation, so read both labels together.
# shellcheck disable=SC2016 # Podman expands the Go template variables.
inspect_home_metadata() {
    local format='{{range $key, $value := .Labels}}{{if eq $key "jailbox.ephemeral-home"}}{{if eq $value "true"}}true{{else if eq $value "false"}}false{{else}}corrupt{{end}}{{end}}{{end}}'
    if [[ "$1" = setup ]]; then
        format+='|{{range $key, $value := .Labels}}{{if eq $key "jailbox.home-generation"}}{{if or (eq $value "plain") (eq (len $value) 64)}}{{$value}}{{else}}invalid{{end}}{{end}}{{end}}|'
    fi
    podman volume inspect "$VOLUME_NAME" --format "$format" || \
        die "could not inspect retention metadata for home '$VOLUME_NAME'; no resources were changed"
}

normalize_home_retention() {
    local policy=$1
    case "$policy" in
        "") printf 'false\n' ;;
        true|false|corrupt) printf '%s\n' "$policy" ;;
        *) die "unexpected home retention inspection result for '$VOLUME_NAME'" ;;
    esac
}

home_retention_policy() {
    local policy
    policy=$(inspect_home_metadata retention) || return $?
    normalize_home_retention "$policy"
}

home_clean_guidance() {
    printf "Run 'jailbox --clean' and then 'jailbox up'; --clean permanently deletes this project's home and runtime state."
}

home_setup_recovery() {
    if [[ "$1" = true ]]; then
        printf "Run 'jailbox stop' to delete the recorded ephemeral home, then relaunch."
    else
        printf "The persistent home is retained. Recover its contents before using 'jailbox --clean', which permanently deletes the home and runtime state."
    fi
}

home_setup_record_path() {
    printf '%s/home-setup-complete' "$SSH_DIR"
}

require_completed_home_setup() {
    local policy=$1 generation=$2 record
    # A required generation stays pending until its exact receipt exists.
    [[ -n "$generation" && "$generation" != plain ]] || return 0
    record=$(home_setup_record_path) || return 1
    validate_ssh_state_path || return 1
    if is_config_digest_value "$generation" &&
        validate_ssh_file "$SSH_DIR" 700 directory &&
        validate_ssh_file "$record" 600 file &&
        cmp -s "$record" <(printf '%s\n' "$generation"); then
        return 0
    fi
    die "home '$VOLUME_NAME' has pending or unverified setup; refusing launch and attachment. $(home_setup_recovery "$policy")"
}

# Read-only launch/attachment policy check. Exits with recovery guidance for
# incompatible or corrupt retention; stop uses the recorded policy separately.
require_compatible_home() {
    local policy metadata generation
    local -a present=()

    resolve_present_resources present "volume:$VOLUME_NAME" "container:$CONTAINER_NAME"
    [[ " ${present[*]} " == *" volume:$VOLUME_NAME "* ]] || return 0
    metadata=$(inspect_home_metadata setup) || return $?
    [[ "$metadata" = *'|'*'|' ]] || die "invalid setup metadata for home '$VOLUME_NAME'"
    policy=$(normalize_home_retention "${metadata%%|*}") || return $?
    generation=${metadata#*|}
    generation=${generation%|}
    case "$policy" in
        corrupt)
            die "home '$VOLUME_NAME' has corrupt retention metadata; refusing reuse. $(home_clean_guidance)"
            ;;
        false)
            if [ "$EPHEMERAL_HOME" != false ]; then
                if [ "$EPHEMERAL_HOME_INFERRED" = true ]; then
                    die "home '$VOLUME_NAME' is persistent; setup defaults to an ephemeral home. Set EPHEMERAL_HOME=false (JAILBOX_CONFIG_EPHEMERAL_HOME=false for machine callers) to retain it. $(home_clean_guidance)"
                fi
                die "home '$VOLUME_NAME' is persistent; refusing a change to ephemeral. $(home_clean_guidance)"
            fi
            ;;
        true)
            [[ " ${present[*]} " == *" container:$CONTAINER_NAME "* ]] || \
                die "home '$VOLUME_NAME' is an orphaned ephemeral home; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up'"
            [ "$EPHEMERAL_HOME" = true ] || \
                die "home '$VOLUME_NAME' is ephemeral; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up' to change to persistent"
            ;;
    esac
    require_completed_home_setup "$policy" "$generation"
}

create_home_volume() {
    # In Podman's rootless parent namespace, 0:0 is the invoking host
    # user/group. The runtime maps those owners to its selected managed ID.
    podman volume create --label "jailbox.ephemeral-home=$EPHEMERAL_HOME" \
        --label "jailbox.home-generation=$1" --opt o=uid=0,gid=0 "$VOLUME_NAME"
}

remove_home_setup_record() {
    local record
    record=$(home_setup_record_path) || return 1
    if [[ -e "$record" || -L "$record" ]]; then
        validate_ssh_state_path || return 1
        rm -rf -- "$record" || return 1
    fi
}
