# commands — version

run_version() {
    local version
    version=$(jailbox_version) || return 1
    printf 'jailbox %s\n' "$version"
}
