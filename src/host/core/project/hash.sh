# Project identity is the first 12 lowercase hexadecimal SHA-256 characters
# of the canonical physical project path. A missing or failed hash tool refuses
# identity construction; there is no fallback identity.

# Human-readable slug from the project directory name. The prefix is used in
# image tags too, so the slug must satisfy the strictest naming rules (OCI
# repository names): lowercase alphanumerics and single dashes only. Empty
# when nothing survives sanitization.
jailbox_project_slug_for_path() {
    local base
    base=$(basename "$1") || return 1
    printf '%s' "$base" |
        tr '[:upper:]' '[:lower:]' |
        tr -c 'a-z0-9' '-' |
        cut -c1-24 |
        sed 's/--*/-/g; s/^-//; s/-$//'
}

# Shared prefix for all per-project Podman resources (container, proxy,
# volume, networks, images). The slug is cosmetic; the hash is the identity.
jailbox_resource_prefix_for_path() {
    local slug hash

    hash=$(jailbox_project_hash_for_path "$1") || return 1
    slug=$(jailbox_project_slug_for_path "$1") || return 1
    if [ -n "$slug" ]; then
        printf 'jailbox-%s-%s\n' "$slug" "$hash"
    else
        printf 'jailbox-%s\n' "$hash"
    fi
}

jailbox_project_hash_for_path() {
    local digest

    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(printf '%s' "$1" | sha256sum) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        digest=$(printf '%s' "$1" | shasum -a 256) || return 1
    else
        echo "Error: required command not found: sha256sum or shasum" >&2
        return 1
    fi

    digest="${digest%% *}"
    digest="${digest:0:12}"
    if [[ ! "$digest" =~ ^[0-9a-f]{12}$ ]]; then
        echo "Error: SHA-256 tool produced an unusable project hash" >&2
        return 1
    fi
    printf '%s\n' "$digest"
}

jailbox_project_hash_port_offset() {
    local hash

    hash="$1"
    # Reject anything but a complete project hash: an empty or truncated value
    # would silently collapse distinct projects onto one offset.
    if [[ ! "$hash" =~ ^[0-9a-f]{12}$ ]]; then
        echo "Error: internal error: port offset requires a 12-character project hash" >&2
        return 1
    fi
    # The first 8 characters are enough: 32 bits covers the 0-16382 offset
    # range and stays inside shell arithmetic limits.
    printf '%s\n' "$((16#${hash:0:8} % 16383))"
}
