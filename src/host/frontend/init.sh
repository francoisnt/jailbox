# shellcheck disable=SC2030,SC2031 # Cleanup reads locals in the owning subshell.
# Local initialization, independent of core identity and sandbox inventory.
# file-policy.sh supplies frontend diagnostics and trusted-path checks.

cleanup_init_config() {
    local status=$?
    if [[ -n "$tmp_file" ]] && ! rm -f -- "$tmp_file"; then
        printf 'Error: could not clean temporary config: %s\n' "$tmp_file" >&2
        [[ "$status" != 0 ]] || status=1
    fi
    exit "$status"
}

write_init_template() {
    local project=$1 candidate
    printf '%s\n' \
        '# Additional project paths mounted read-only inside the sandbox.' \
        'READONLY_PATHS=' \
        '# Add selected suggestions comma-separated to the single READONLY_PATHS assignment.' || return $?
    # Existence only: never open candidate contents (in particular .env).
    for candidate in .env .git/hooks .git/config AGENTS.md CLAUDE.md .github/workflows; do
        if [[ -e "$project/$candidate" ]]; then
            printf '# %s\n' "$candidate" || return $?
        fi
    done
}

init_project_config() (
    local project destination tmp_file="" nested_link
    project=$(cd -- "$1" && pwd -P) || die 'cannot resolve project directory'
    check_config_path "$project" || return $?
    destination=$project/jailbox.conf
    [[ ! -e "$destination" && ! -L "$destination" ]] || die 'jailbox.conf already exists; refusing to overwrite it'
    trap cleanup_init_config EXIT
    trap 'exit 1' HUP INT TERM
    tmp_file=$(mktemp "$project/.jailbox.conf.tmp.XXXXXX") || die 'could not create temporary project configuration'
    write_init_template "$project" > "$tmp_file" || die 'could not write temporary project configuration'
    if ln -- "$tmp_file" "$destination" 2>/dev/null; then
        if [[ ! -L "$destination" && -f "$destination" && "$tmp_file" -ef "$destination" ]]; then
            rm -f -- "$tmp_file" || die 'could not clean temporary config'
            tmp_file=""
            printf 'Created %s\n' "$destination"
            return $?
        fi
        # ln can create a nested link if a directory appears during publication.
        nested_link=$destination/${tmp_file##*/}
        if [[ -e "$nested_link" && "$tmp_file" -ef "$nested_link" ]]; then
            rm -f -- "$nested_link" || die 'could not clean temporary nested config link'
        fi
    fi
    [[ ! -e "$destination" && ! -L "$destination" ]] || die 'jailbox.conf already exists; refusing to overwrite it'
    die "could not publish $destination"
)
