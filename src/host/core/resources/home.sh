# resources — home

# Classify inside the template: arbitrary label bytes (including trailing
# newlines) must never become valid through shell command substitution. An
# absent key, a present empty value, and failed inspection stay distinct.
# Prints false (persistent, including legacy unlabeled homes), true (ephemeral),
# or corrupt. Failed inspection exits; it never becomes a deletion decision.
home_retention_policy() {
    local policy

    policy=$(podman volume inspect "$VOLUME_NAME" --format \
        '{{range $key, $value := .Labels}}{{if eq $key "jailbox.ephemeral-home"}}{{if eq $value "true"}}true{{else if eq $value "false"}}false{{else}}corrupt{{end}}{{end}}{{end}}') || \
        die "could not inspect retention metadata for home '$VOLUME_NAME'; no resources were changed"
    case "$policy" in
        "") printf 'false\n' ;;
        true|false|corrupt) printf '%s\n' "$policy" ;;
        *) die "unexpected home retention inspection result for '$VOLUME_NAME'" ;;
    esac
}

home_clean_guidance() {
    printf "Run 'jailbox --clean' and then 'jailbox up'; --clean permanently deletes this project's home and runtime state."
}

# Read-only launch/attachment policy check. Exits with recovery guidance for
# incompatible or corrupt retention; stop uses the recorded policy separately.
require_compatible_home() {
    local policy
    local -a present=()

    resolve_present_resources present "volume:$VOLUME_NAME" "container:$CONTAINER_NAME"
    [[ " ${present[*]} " == *" volume:$VOLUME_NAME "* ]] || return 0
    policy=$(home_retention_policy) || return $?
    case "$policy" in
        corrupt)
            die "home '$VOLUME_NAME' has corrupt retention metadata; refusing reuse. $(home_clean_guidance)"
            ;;
        false)
            [ "$EPHEMERAL_HOME" = false ] || \
                die "home '$VOLUME_NAME' is persistent; refusing a change to ephemeral. $(home_clean_guidance)"
            ;;
        true)
            [[ " ${present[*]} " == *" container:$CONTAINER_NAME "* ]] || \
                die "home '$VOLUME_NAME' is an orphaned ephemeral home; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up'"
            [ "$EPHEMERAL_HOME" = true ] || \
                die "home '$VOLUME_NAME' is ephemeral; run 'jailbox stop' (deletes the recorded ephemeral home) and then 'jailbox up' to change to persistent"
            ;;
    esac
}

ensure_home_volume() {
    local volume_path
    local -a present=()

    resolve_present_resources present "volume:$VOLUME_NAME" || return 1
    if [ -z "${present[*]-}" ]; then
        podman volume create --label "jailbox.ephemeral-home=$EPHEMERAL_HOME" "$VOLUME_NAME" || return 1
        volume_path=$(podman volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}') || return 1
        # In Podman's rootless parent namespace, 0:0 is the invoking host
        # user/group. The runtime maps those owners to its selected managed ID.
        # Only initialize the new volume root; retained home contents are untouched.
        podman unshare chown 0:0 "$volume_path" || return 1
    fi
}
