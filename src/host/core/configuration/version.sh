# configuration — version

# The release stamp is data, never shell code. Keep this accessor shared with
# compatibility consumers so they use exactly the token printed by --version.
jailbox_version() {
    local stamp="$SCRIPT_DIR/VERSION" value token

    if [[ ! -e "$stamp" && ! -L "$stamp" ]]; then
        printf 'dev\n'
        return 0
    fi
    if [[ ! -f "$stamp" || -L "$stamp" ]]; then
        printf 'Error: invalid jailbox version stamp.\n' >&2
        return 1
    fi
    # A sentinel preserves trailing newlines; cmp also catches NUL bytes that
    # Bash cannot represent. Accept exactly one newline-terminated record.
    value=$(cat "$stamp" && printf '.') || return 1
    value=${value%.}
    token=${value%$'\n'}
    if [[ "$value" != "$token"$'\n' || ! "$token" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
        ! cmp -s "$stamp" <(printf '%s' "$value"); then
        printf 'Error: invalid jailbox version stamp.\n' >&2
        return 1
    fi
    printf '%s' "$value"
}
