# shellcheck disable=SC2329
# Shared behavioral checks for the two generated-file writers. The caller
# supplies a zero-argument writer and its destination in an isolated fixture.
assert_file_publication() (
    local writer=$1 destination=$2 directory mode fault status before_traps before_options before_pwd before_flags
    directory=$(dirname "$destination")
    mkdir -p "$directory"
    chmod 700 "$directory"
    trap ':' HUP INT TERM
    before_traps=$(trap -p)
    before_options=$(set +o)
    before_pwd=$PWD
    before_flags=$-
    printf 'unrelated\n' > "$directory/unrelated"

    # All wrappers keep successful tool behavior and inject only the selected
    # boundary. TERM is delivered inside the writer's subshell after allocation.
    mkdir() { [[ "$fault" != mkdir ]] || return 42; command mkdir "$@"; }
    mktemp() {
        [[ "$fault" != mktemp ]] || return 42
        command mktemp "$@"
        [[ "$fault" != allocated ]] || return 42
    }
    chmod() { [[ "$fault" != chmod ]] || return 42; command chmod "$@"; }
    cat() { [[ "$fault" != write ]] || { printf partial; return 42; }; command cat "$@"; }
    git() {
        if [[ " $* " == *' --file '* ]]; then
            [[ "$fault" != write ]] || return 42
        fi
        command git "$@"
    }
    mv() {
        case "$fault" in
            mv|cleanup) return 43 ;;
            INT) kill -INT "$BASHPID"; return 42 ;;
            TERM) kill -TERM "$BASHPID"; return 42 ;;
            HUP) kill -HUP "$BASHPID"; return 42 ;;
        esac
        command mv "$@"
    }
    rm() { [[ "$fault" != cleanup ]] || return 44; command rm "$@"; }

    for mode in 0022 0002; do
        umask "$mode"
        for fault in mkdir mktemp allocated write chmod mv HUP INT TERM cleanup success; do
            printf 'original\n' > "$destination"
            command chmod 600 "$destination"
            before_options=$(set +o)
            status=0
            # This conditional call deliberately suppresses errexit throughout
            # the writer; each required command must enforce its own contract.
            if "$writer" > "$directory/output" 2> "$directory/error"; then
                [[ "$fault" == success ]] || { echo "Accepted publication failure: $writer $fault" >&2; exit 1; }
            else
                status=$?
                [[ "$fault" != success ]] || { command cat "$directory/error" >&2; exit 1; }
            fi
            [[ $(trap -p) == "$before_traps" && $(set +o) == "$before_options" && "$PWD" == "$before_pwd" && $- == "$before_flags" ]]
            [[ $(command cat "$directory/unrelated") == unrelated ]]
            [[ $(umask) == "$mode" ]]
            if [[ "$fault" != success ]]; then
                [[ $(command cat "$destination") == original && "$status" -ne 0 ]]
            else
                [[ $(command cat "$destination") != original ]]
                [[ $(LC_ALL=C ls -l "$destination") == -rw-------* ]]
            fi
            if [[ "$fault" == cleanup ]]; then
                grep -q 'could not clean temporary' "$directory/error"
                [[ -n $(find "$directory" -name '*.tmp.*' -print) ]]
                command rm -f "$directory/"*.tmp.*
            else
                [[ -z $(find "$directory" -name '*.tmp.*' -print) ]]
            fi
        done
    done
)
