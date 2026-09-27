# Shared installer/runtime utility checks. Keep compatible with Bash 3.2.
# Probe behavior on fixed inputs without creating files or changing the host.

host_utility_error() {
    printf 'Error: jailbox requires %s on PATH.\n' "$1" >&2
    # shellcheck disable=SC2016 # Print commands for the user's shell to evaluate.
    printf '%s\n' \
        'On macOS, install GNU coreutils: brew install coreutils' \
        'Then run: export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"' \
        'On Linux, install the coreutils package using your package manager.' \
        'Retry from the same shell after correcting PATH.' >&2
    return 1
}

require_host_realpath() {
    local result
    if ! result=$(realpath -e -- / 2>/dev/null) || [ "$result" != / ] ||
        ! result=$(realpath -m -- /../ 2>/dev/null) || [ "$result" != / ] ||
        ! result=$(realpath --relative-to=/ -- / 2>/dev/null) || [ "$result" != . ]; then
        host_utility_error 'realpath supporting -e, -m, --relative-to, and --'
        return 1
    fi
}

require_host_sort() (
    set -o pipefail
    local result
    # Convert framing only after sort; Bash strings cannot retain NUL bytes.
    if ! result=$(printf 'b\0a\0' | LC_ALL=C sort -z 2>/dev/null | tr '\000' '\n') ||
        [ "$result" != "$(printf 'a\nb')" ]; then
        host_utility_error 'sort supporting -z (NUL-delimited records)'
        return 1
    fi
)
