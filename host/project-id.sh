# Shared project identity helpers.

jailbox_project_hash_for_path() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -c1-12
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-12
    else
        printf '%s' "$1" | cksum | cut -d' ' -f1
    fi
}

jailbox_project_hash_port_offset() {
    local hash

    hash="$1"
    [ -n "$hash" ] || hash=0
    # Branches are mutually exclusive: cksum returns pure decimal digits, while
    # sha256sum/shasum return hexadecimal. The hex branch uses the first 8
    # characters of the 12-character project hash because 32 bits is enough for
    # the 0-16382 port-offset range and stays inside shell arithmetic limits.
    if [[ "$hash" =~ ^[0-9]+$ && "${#hash}" -le 10 ]]; then
        printf '%s\n' "$((hash % 16383))"
    else
        printf '%s\n' "$((16#${hash:0:8} % 16383))"
    fi
}
