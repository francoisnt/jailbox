# resources — inventory

# Exact deterministic names are this project's identity. Podman exposes
# existence and labels differently per resource type, so probing is
# type-specific while the decision made from it is not.
# Tests may request engine diagnostics; ordinary CLI callers retain quiet
# probes and provide their command-specific errors.
# Returns the engine status: 0 present, 1 absent, other nonzero inspection error.
# It performs no cleanup and publishes no classification; do not treat all
# nonzero statuses as absence or use incidental engine stdout as an answer.
jailbox_resource_exists() {
    case "$1" in
        container|volume|network|image) ;;
        *) die "internal error: unknown jailbox resource type '$1'" ;;
    esac
    case "${3:-}" in
        --diagnostics) podman "$1" exists "$2" ;;
        '') podman "$1" exists "$2" 2>/dev/null ;;
        *) die "internal error: unknown resource probe option '$3'" ;;
    esac
}

# Read the fixed-width digest label, rejecting extra bytes inside the engine
# before command substitution can strip trailing newlines. An absent label
# stays empty; inspection failure remains an operational error.
jailbox_resource_label() {
    local kind name label

    kind="$1"
    name="$2"
    label="$3"
    case "$kind" in
        container)
            podman container inspect "$name" \
                --format '{{with index .Config.Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
            ;;
        volume)
            podman volume inspect "$name" \
                --format '{{with index .Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
            ;;
        network)
            podman network inspect "$name" \
                --format '{{with index .Labels "'"$label"'"}}{{if eq (len .) 64}}{{.}}{{else}}invalid{{end}}{{end}}'
            ;;
        *) die "internal error: unknown jailbox resource type '$kind'" ;;
    esac
}

# Resolve "TYPE:NAME" targets into the present removal set named by the first
# argument. Every target is probed before anything is removed, so a Podman
# probe failure aborts the whole operation with nothing mutated.
# Populates the named caller array; an inspection error exits through die, so
# any partially populated array must not be used after failed observation.
#
# Presence under the derived name is the only test. Deletion deliberately does
# not consult the configuration digest: stop and --clean stay usable when
# configuration is missing or malformed, so an occupant of a derived name is
# removed whatever created it.
resolve_present_resources() {
    # shellcheck disable=SC2178 # Nameref receives an array name.
    local -n present_ref="$1"
    shift
    local target kind name status inventory
    local -A counts=() listings=()

    present_ref=()
    for target in "$@"; do
        kind=${target%%:*}
        case "$kind" in
            container|network|volume) ;;
            image) continue ;;
            *) die "internal error: unknown resource type '$kind'" ;;
        esac
        counts[$kind]=$((${counts[$kind]:-0} + 1))
    done
    # Listings win only for sufficiently large groups. Never retain an
    # inventory beyond this call, especially across a lifecycle mutation.
    for kind in container network volume; do
        case "$kind" in
            container)
                [[ ${counts[$kind]:-0} -ge 5 ]] || continue
                inventory=$(podman container ls --all --format '{{.Names}}') || die 'could not determine whether containers exist with Podman'
                ;;
            *)
                [[ ${counts[$kind]:-0} -ge 2 ]] || continue
                inventory=$(podman "$kind" ls --format '{{.Name}}') || die "could not determine whether ${kind}s exist with Podman"
                ;;
        esac
        listings[$kind]=$'\n'"$inventory"$'\n'
    done
    for target in "$@"; do
        kind="${target%%:*}"
        name="${target#*:}"
        if [[ -v listings[$kind] ]]; then
            if [[ ${listings[$kind]} = *$'\n'"$name"$'\n'* ]]; then present_ref+=("$target"); fi
            continue
        fi
        status=0
        jailbox_resource_exists "$kind" "$name" || status=$?
        case "$status" in
            0) present_ref+=("$target") ;;
            1) ;;
            *) die "could not determine whether $kind '$name' exists with Podman" ;;
        esac
    done
}

remove_project_resource() {
    local kind name removal_status=0 probe_status=0

    kind="${1%%:*}"
    name="${1#*:}"
    case "$kind" in
        container)
            podman stop "$name" 2>/dev/null || true
            podman rm "$name" || removal_status=$?
            ;;
        volume|network|image)
            podman "$kind" rm "$name" || removal_status=$?
            ;;
    esac
    [ "$removal_status" -ne 0 ] || return 0
    # A target may disappear after preflight. Accept confirmed absence, but
    # never treat a failed recheck as absence or parse engine error wording.
    jailbox_resource_exists "$kind" "$name" || probe_status=$?
    [ "$probe_status" -eq 1 ] || \
        die "could not remove $kind '$name' or confirm its absence; retry the cleanup after resolving the error"
}
