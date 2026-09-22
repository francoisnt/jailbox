# Compatibility coordination owns the current inspection snapshot, shared by
# launch and attachment. It is not a live inventory or a cross-command cache;
# callers use it only after successful inspection and before dependent mutation.
OBSERVED_RESOURCES=()
OBSERVED_DEV_STATE=absent
OBSERVED_PROXY_STATE=absent

# Query the current compatibility snapshot; return 0 for present, 1 for absent.
# No engine call, refresh, or launch-bookkeeping update occurs here.
observed_resource_present() {
    local target
    for target in "${OBSERVED_RESOURCES[@]}"; do
        [ "$target" != "$1" ] || return 0
    done
    return 1
}

sandbox_stop_guidance() {
    local policy=false probe=0
    jailbox_resource_exists volume "$VOLUME_NAME" || probe=$?
    case "$probe" in
        0) policy=$(home_retention_policy) || return 1 ;;
        1) ;;
        *) printf 'Could not inspect home retention; resolve the engine error before choosing recovery.\n' >&2; return 1 ;;
    esac
    printf "Run 'jailbox stop' then 'jailbox up'. Stop removes containers, networks and SSH credentials; "
    case "$policy" in
        true) printf 'it deletes the recorded ephemeral home.\n' ;;
        *) printf 'it preserves the persistent home.\n' ;;
    esac
}

refuse_sandbox() {
    local guidance
    if [ "$LAUNCH_CONVERGING" = true ]; then
        fail_sandbox_readiness "$@"
    fi
    guidance=$(sandbox_stop_guidance) || die "could not inspect home retention; resolve the engine error before choosing recovery"
    die "refusing sandbox reuse: $*. $guidance"
}

# Read-only with respect to sandbox resources. Refreshes OBSERVED_* and derived
# network/image-selection/mount inputs. Does not reset or record launch attempts.
# Returns nonzero or exits with recovery guidance on failure; partial outputs
# must not authorize mutation. Launch and attach differ only in input selection.
inspect_sandbox_compatibility() {
    local mode="${1:-launch}"
    resolve_present_resources OBSERVED_RESOURCES \
        "container:$CONTAINER_NAME" "container:$PROXY_NAME" \
        "network:$NETWORK_NAME" "network:${NETWORK_NAME}-internal" \
        "network:${NETWORK_NAME}-external" "volume:$VOLUME_NAME"
    OBSERVED_DEV_STATE=$(inspect_container_lifecycle_state "$CONTAINER_NAME") || return 1
    OBSERVED_PROXY_STATE=$(inspect_container_lifecycle_state "$PROXY_NAME") || return 1
    inspect_network_compatibility || return 1
    validate_ssh_state_path || return 1
    validate_runtime_files || return 1
    if [ "$OBSERVED_DEV_STATE" = absent ]; then
        require_ssh_generation_absent || { sandbox_stop_guidance >&2; return 1; }
    else
        observed_resource_present "volume:$VOLUME_NAME" || refuse_sandbox 'development container has no home volume'
        validate_ssh_resume || { sandbox_stop_guidance >&2; return 1; }
    fi
    # Selection is needed before effective protected mounts can be inspected.
    if [ -z "$DEV_IMAGE" ]; then
        if [ "$mode" = launch ]; then
            select_dev_containerfile_for_launch || return 1
        else
            local selection_status=0
            discover_dev_containerfile || selection_status=$?
            [ "$selection_status" -le 2 ] || return "$selection_status"
        fi
    fi
    finalize_effective_readonly_paths || return 1
    validate_sandbox_structure
}

# Re-inspects container structure and relationships, without live service probes
# or repair. Required inspection failures and incompatibilities refuse reuse.
validate_sandbox_structure() {
    local name present=()
    resolve_present_resources present "container:$CONTAINER_NAME" "container:$PROXY_NAME"
    for name in "$CONTAINER_NAME" "$PROXY_NAME"; do
        [[ " ${present[*]} " == *" container:$name "* ]] || continue
        validate_container_hardening "$name" || return 1
        validate_container_networks "$name" || return 1
        if [ "$name" = "$CONTAINER_NAME" ]; then
            validate_development_mounts || return 1
        else
            validate_proxy_configuration || return 1
        fi
    done
}

# Every independently surviving policy-bearing resource, including the network
# roles this configuration's network mode does not request: a stale network
# left by the other mode is just as incompatible as one in use.
config_digest_inventory() {
    printf '%s\n' \
        "container:$CONTAINER_NAME" \
        "container:$PROXY_NAME" \
        "network:$NETWORK_NAME" \
        "network:${NETWORK_NAME}-internal" \
        "network:${NETWORK_NAME}-external"
}

config_digest_incompatibility() {
    local recorded

    recorded="$1"
    case "$recorded" in
        ""|"<no value>") printf 'no configuration digest label\n' ;;
        *)
            if is_config_digest_value "$recorded"; then
                printf 'a digest from a different configuration or jailbox version\n'
            else
                printf 'a malformed configuration digest label\n'
            fi
            ;;
    esac
}

# The reuse gate. Every inventory member that already exists must carry
# exactly the current digest; missing, malformed, inconsistent, and mismatched
# labels all refuse here, before anything is created, removed, or reused.
require_compatible_project_resources() {
    local target kind name recorded status reason guidance summary policy
    local -a incompatible=() homes=()

    assert_config_digest_ready
    while IFS= read -r target; do
        kind="${target%%:*}"
        name="${target#*:}"
        status=0
        jailbox_resource_exists "$kind" "$name" || status=$?
        case "$status" in
            0) ;;
            1) continue ;;
            *) die "could not determine whether $kind '$name' exists with Podman" ;;
        esac

        recorded=$(jailbox_resource_label "$kind" "$name" "$CONFIG_DIGEST_LABEL") || \
            die "could not inspect configuration digest on $kind '$name'; no sandbox resources were changed"
        [ "$recorded" = "$CONFIG_DIGEST" ] && continue
        reason=$(config_digest_incompatibility "$recorded")
        incompatible+=("$kind '$name' carries $reason")
    done < <(config_digest_inventory)

    [ -z "${incompatible[*]-}" ] && return 0

    summary=""
    for reason in "${incompatible[@]}"; do
        summary="${summary:+$summary; }$reason"
    done
    guidance="Run 'jailbox stop' and then 'jailbox up' to recreate the containers and networks."
    resolve_present_resources homes "volume:$VOLUME_NAME"
    if [ -n "${homes[*]-}" ]; then
        policy=$(home_retention_policy) || return 1
        case "$policy" in
            true) guidance+=" Stop deletes the recorded ephemeral home." ;;
            *) guidance+=" Stop preserves the persistent home." ;;
        esac
    fi
    # Attempt the required refusal before advisory context. Output failures
    # must neither suppress this attempt nor change the refusal's exit status.
    # Keep the prefix consistent with die in host/core/common.sh; calling die here
    # would exit before the advisory context can be attempted.
    printf 'Error: %s\n' "refusing to reuse project resources that do not match this configuration and jailbox version: $summary. $guidance" >&2 || true
    if [[ ${1:-} = attach ]]; then
        print_attachment_digest_context >&2 || true
    fi
    exit 1
}

# Current-side context only: the digest cannot recover launch-side inputs.
# Iterate public declarations, then name-only metadata; never serialize values.
print_attachment_digest_context() {
    local key name prefix separator=""
    local -a names=() selected=()
    mapfile -t names < <(environment_config_names)
    for key in "${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}"; do
        prefix="JAILBOX_CONFIG_$key"
        for name in "${names[@]}"; do
            if [[ "$name" = "$prefix" ]]; then
                selected+=("$name")
            elif is_config_array_key "$key" && [[ "$name" =~ ^${prefix}_(0|[1-9][0-9]*)$ ]]; then
                selected+=("$name")
            fi
        done
    done
    if [[ -n ${selected[*]-} ]]; then
        printf 'Current invocation configuration names: '
        for name in "${selected[@]}"; do
            printf '%s%s' "$separator" "$name"
            separator=', '
        done
        printf '\n'
    else
        printf 'Current invocation has no recognized JAILBOX_CONFIG_* environment variables.\n'
    fi
    printf 'This is current-side context only; it cannot identify which launch-side key differed. Attachment requires the same effective policy, not the same provenance.\n'
}

refuse_local_validation() {
    if [ "$LAUNCH_CONVERGING" = true ]; then fail_sandbox_readiness "$@"; fi
    die "$*"
}

refuse_downloader_sync() {
    if [ "$LAUNCH_CONVERGING" = true ]; then fail_sandbox_readiness "$@"; fi
    die "$*; run 'jailbox up' before attaching"
}
