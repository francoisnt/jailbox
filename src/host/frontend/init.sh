# shellcheck disable=SC2030,SC2031 # Cleanup reads locals in the owning subshell.
# Local initialization, independent of core identity and sandbox inventory.
# file-policy.sh supplies frontend diagnostics and trusted-path checks.

cleanup_init_config() {
    local status=$? index temporary destination
    local operation_status=$status
    for index in "${!init_temporary[@]}"; do
        temporary=${init_temporary[index]}
        destination=${init_destinations[index]}
        if [[ $operation_status != 0 && -n $temporary && ! -L $destination && $temporary -ef $destination ]]; then
            rm -f -- "$destination" || printf 'Error: could not roll back %s\n' "${destination##*/}" >&2
        fi
        if [[ -n $temporary ]] && ! rm -f -- "$temporary"; then
            printf 'Error: could not clean temporary config: %s\n' "${temporary##*/}" >&2
            [[ $status != 0 ]] || status=1
        fi
    done
    exit "$status"
}

publish_init_file() {
    local temporary=$1 destination=$2 nested_link
    if ln -- "$temporary" "$destination" 2>/dev/null; then
        if [[ ! -L $destination && -f $destination && $temporary -ef $destination ]]; then
            return 0
        fi
        # ln can create a nested link if a directory appears during publication.
        nested_link=$destination/${temporary##*/}
        if [[ -e $nested_link && $temporary -ef $nested_link ]]; then
            rm -f -- "$nested_link" || die 'could not clean temporary nested config link'
        fi
    fi
    [[ ! -e $destination && ! -L $destination ]] || die "${destination##*/} already exists; refusing to overwrite it"
    die "could not publish ${destination##*/}"
}

write_init_template() {
    local project=$1 candidate
    cat -- "${BASH_SOURCE[0]%/*}/jailbox.conf.template" || return $?
    # Existence only: never open candidate contents (in particular .env).
    for candidate in .env .git/hooks .git/config AGENTS.md CLAUDE.md .github/workflows; do
        if [[ -e "$project/$candidate" ]]; then
            printf '# %s\n' "$candidate" || return $?
        fi
    done
}

init_project_config() (
    local project destination candidate create_containerfile=true index
    local -a init_temporary=() init_destinations=()
    project=$(cd -- "$1" && pwd -P) || die 'cannot resolve project directory'
    check_config_path "$project" || return $?
    destination=$project/jailbox.conf
    [[ ! -e "$destination" && ! -L "$destination" ]] || die 'jailbox.conf already exists; refusing to overwrite it'
    for candidate in Containerfile Dockerfile .devcontainer/Containerfile .devcontainer/Dockerfile; do
        if [[ -e $project/$candidate || -L $project/$candidate ]]; then
            create_containerfile=false
            break
        fi
    done
    trap cleanup_init_config EXIT
    trap 'exit 1' HUP INT TERM
    init_destinations=("$destination")
    init_temporary[0]=$(mktemp "$project/.jailbox.conf.tmp.XXXXXX") || die 'could not create temporary project configuration'
    write_init_template "$project" > "${init_temporary[0]}" || die 'could not write temporary project configuration'
    if [[ $create_containerfile == true ]]; then
        init_destinations+=("$project/Containerfile")
        init_temporary[1]=$(mktemp "$project/.Containerfile.tmp.XXXXXX") || die 'could not create temporary Containerfile'
        cat -- "${BASH_SOURCE[0]%/*}/Containerfile.template" > "${init_temporary[1]}" || die 'could not write temporary Containerfile'
    fi
    for index in "${!init_temporary[@]}"; do
        publish_init_file "${init_temporary[index]}" "${init_destinations[index]}" || return $?
    done
    for destination in "${init_destinations[@]}"; do
        printf 'Created %s\n' "${destination##*/}" || return $?
    done
)
