# Version-bound configuration digest.
#
# One digest answers "was this resource created by this jailbox version from
# this configuration?" for every independently surviving policy-bearing
# resource: both project containers and all three project networks. A match is
# necessary but never sufficient for reuse or attachment; structural validation
# stays a separate requirement.
#
# The digest covers references, not content: a mutable or re-pulled DEV_IMAGE
# tag, edited Containerfile bytes, and changed build-context contents never
# change it. Only the exact jailbox version, the effective machine
# configuration values, and the identity of the selected Containerfile do.
#
# The persistent home volume is deliberately outside the inventory. It carries
# no immutable security-relevant creation settings; its containment comes from
# container mount and runtime policy applied at every launch.

CONFIG_DIGEST_STREAM_VERSION="jailbox-config-digest-v1"
CONFIG_DIGEST_LABEL="jailbox.config-digest"

# Array keys whose members are a set: reordering or repeating them expresses
# the same policy, so they are serialized deduplicated in bytewise LC_ALL=C
# order. Every other array key keeps its configured order, because order can be
# significant — mount precedence, for one — and over-invalidating is the safe
# default. Add a key here only after proving it is set-valued; portable
# coverage proves every member is also a CONFIG_ARRAY_KEYS member.
DIGEST_SET_ARRAY_KEYS=(
    EGRESS_ALLOW
)

CONFIG_DIGEST=""
CONFIG_DIGEST_LABEL_ARGS=()

initialize_config_digest_state() {
    CONFIG_DIGEST=""
    CONFIG_DIGEST_LABEL_ARGS=()
}

# Defense in depth over 03.1's value rejection and the path checks in
# classify_trusted_file: TAB and newline framing is only unambiguous while
# every encoded field is control-character-free, so assert it at the point of
# encoding rather than trusting the producers.
config_digest_assert_field() {
    local description

    description="$1"
    if contains_control_character "$2"; then
        die "refusing to hash $description containing an ASCII control character"
    fi
}

config_digest_is_set_array_key() {
    local key candidate

    key="$1"
    for candidate in "${DIGEST_SET_ARRAY_KEYS[@]}"; do
        [ "$candidate" = "$key" ] && return 0
    done
    return 1
}

# Print one array key's members in serialization order, one per line. Members
# are control-character-free, so newline framing is lossless here too.
config_digest_array_members() {
    local key
    local -n members="$1"

    key="$1"
    [ -n "${members[*]-}" ] || return 0
    if config_digest_is_set_array_key "$key"; then
        printf '%s\n' "${members[@]}" | LC_ALL=C sort -u
    else
        printf '%s\n' "${members[@]}"
    fi
}

# The Containerfile record. DEV_IMAGE wins without inspecting any candidate,
# because a configured image reference means no Containerfile participates in
# the sandbox at all. Otherwise it runs the same trusted selector image
# construction uses, without building or inspecting an image.
#
# The two modes differ only in how a vanished selection is treated: a launch
# has to produce its specific missing-input diagnostic, while an attachment
# records that the selection is gone and lets the caller give ordinary
# stale-sandbox guidance.
config_digest_containerfile_record() {
    local mode status

    mode="$1"
    if [ -n "$DEV_IMAGE" ]; then
        printf 'containerfile\tnone\n'
        return 0
    fi

    case "$mode" in
        launch)
            select_dev_containerfile_for_launch || return $?
            ;;
        attach)
            status=0
            discover_dev_containerfile || status=$?
            case "$status" in
                0) ;;
                1|2)
                    printf 'containerfile\tmissing\n'
                    return 0
                    ;;
                *) return "$status" ;;
            esac
            ;;
        *) die "internal error: unknown configuration digest mode '$mode'" ;;
    esac

    config_digest_assert_field "the Containerfile path" "$SELECTED_DEV_CONTAINERFILE"
    printf 'containerfile\tpath\t%s\n' "$SELECTED_DEV_CONTAINERFILE"
}

# The canonical stream: a version tag, the exact jailbox version, one record
# per declared machine configuration key in declaration order, each array item
# as its own record after its key's count, and the Containerfile record last.
# Its encoding needs no cross-release stability, because the exact version is
# hashed in: a future encoding change is an ordinary digest mismatch.
config_digest_stream() {
    local mode version key value item members_text
    local -a items=()

    mode="$1"
    version=$(jailbox_version) || return 1
    config_digest_assert_field "the jailbox version" "$version"

    printf '%s\n' "$CONFIG_DIGEST_STREAM_VERSION"
    printf 'jailbox-version\t%s\n' "$version"

    for key in "${CONFIG_SCALAR_KEYS[@]}"; do
        value="${!key}"
        config_digest_assert_field "configuration value '$key'" "$value"
        printf 'scalar\t%s\t%s\n' "$key" "$value"
    done

    for key in "${CONFIG_ARRAY_KEYS[@]}"; do
        # Capture rather than read from a process substitution: a failure in
        # the member serialization must abort the digest, never reduce the key
        # to zero items behind a successful mapfile. Command substitution
        # strips the trailing newline, so the empty result is guarded — a
        # here-string restores that newline and would turn no members into one
        # empty member.
        members_text=$(config_digest_array_members "$key") || return 1
        items=()
        [ -z "$members_text" ] || mapfile -t items <<< "$members_text"
        printf 'array\t%s\t%s\n' "$key" "${#items[@]}"
        for item in "${items[@]}"; do
            config_digest_assert_field "configuration item of '$key'" "$item"
            printf 'value\t%s\n' "$item"
        done
    done

    config_digest_containerfile_record "$mode"
}

# 64 lowercase hex from whichever of the two portable tools this host has.
config_digest_hash() {
    local output

    if command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256) || return 1
    else
        die "required command not found: sha256sum or shasum"
    fi
    printf '%s' "${output%% *}"
}

is_config_digest_value() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

config_digest_value() {
    local mode stream digest

    mode="${1:-}"
    [ -n "$mode" ] || die "internal error: configuration digest requires a mode"
    # Hash the stream from a variable rather than through a pipeline: a
    # refusal inside the producer must abort the digest, never leave a hash
    # of a truncated stream behind.
    stream=$(config_digest_stream "$mode") || return 1
    digest=$(printf '%s\n' "$stream" | config_digest_hash) || return 1
    digest="${digest,,}"
    is_config_digest_value "$digest" || \
        die "internal error: configuration digest tool produced an unexpected value"
    printf '%s' "$digest"
}

# Compute the digest for this invocation and prepare the label arguments every
# policy-bearing resource is created with.
compute_config_digest() {
    local digest

    digest=$(config_digest_value "$1") || return 1
    CONFIG_DIGEST="$digest"
    CONFIG_DIGEST_LABEL_ARGS=(--label "$CONFIG_DIGEST_LABEL=$CONFIG_DIGEST")
}

assert_config_digest_ready() {
    if ! is_config_digest_value "${CONFIG_DIGEST:-}" ||
        [ "${#CONFIG_DIGEST_LABEL_ARGS[@]}" -ne 2 ]; then
        die "internal error: policy-bearing resources require a computed configuration digest"
    fi
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
    die "refusing to reuse project resources that do not match this configuration and jailbox version: $summary. $guidance"
}
