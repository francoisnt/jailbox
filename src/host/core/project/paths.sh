# project — paths

# A project may be beneath HOME, but must never expose HOME or jailbox state
# through its writable bind. Resolve missing state ancestors without creating
# them; recovery/inventory commands deliberately do not impose launch policy.
validate_project_boundary() {
    local project home state
    [[ -n ${HOME:-} ]] || { echo 'Error: HOME is required for project isolation' >&2; return 1; }
    reject_control_characters 'project' "$PROJECT_DIR"
    reject_control_characters 'home' "$HOME"
    reject_control_characters 'runtime state' "${XDG_STATE_HOME:-$HOME/.local/state}/jailbox"
    project=$(realpath -e -- "$PROJECT_DIR") || {
        echo 'Error: cannot resolve project directory for isolation checks' >&2; return 1;
    }
    home=$(realpath -e -- "$HOME") || {
        echo 'Error: cannot resolve host HOME for isolation checks' >&2; return 1;
    }
    state=$(realpath -m -- "${XDG_STATE_HOME:-$HOME/.local/state}/jailbox") || {
        echo 'Error: cannot resolve runtime state for isolation checks' >&2; return 1;
    }
    reject_control_characters 'project' "$project"
    reject_control_characters 'home' "$home"
    reject_control_characters 'runtime state' "$state"
    if [[ "$project" = / || "$home" = "$project" || "$home" = "$project/"* ]]; then
        printf 'Error: project %s contains host HOME %s; select a project below or outside HOME\n' "$project" "$home" >&2
        return 1
    fi
    if [[ "$state" = "$project" || "$state" = "$project/"* ]]; then
        printf 'Error: project %s contains jailbox runtime state %s; move the state outside the project\n' "$project" "$state" >&2
        return 1
    fi
}

# Emit project-relative dependencies only. The project root cannot be added as
# an overlay without replacing the writable-project contract, so refuse it.
print_project_protection_target() {
    local target=$1 project=$2 relative
    [[ "$target" != "$project" ]] || {
        echo 'Error: protected symlink requires protecting the entire project; choose a narrower target' >&2
        return 1
    }
    [[ "$target" = "$project/"* ]] || return 0
    relative=${target#"$project"/}
    reject_control_characters 'protected symlink target' "$relative"
    validate_project_mount_path_lexical "$relative" || {
        echo 'Error: protected symlink target is not a valid project mount path' >&2
        return 1
    }
    printf '%s\n' "$relative"
}

# Resolve every component, retaining intermediate link directories as well as
# the final target. Otherwise a writable intermediate link could be retargeted
# after the final target was mounted read-only. No file contents are read.
project_symlink_dependencies() {
    local pending=$1 project=$2 current=/ component rest parent target hops=0 directory_component
    reject_control_characters 'protected symlink' "$pending"
    pending=${pending#/}
    while [[ -n "$pending" ]]; do
        component=${pending%%/*}
        rest=""
        directory_component=false
        [[ "$pending" != */* ]] || { rest=${pending#*/}; directory_component=true; }
        pending=$rest
        case "$component" in
            ''|.) continue ;;
            ..) current=${current%/*}; current=${current:-/}; continue ;;
        esac
        parent=$current
        current=${current%/}/$component
        if [[ -L "$current" ]]; then
            hops=$((hops + 1))
            ((hops <= 40)) || { echo 'Error: protected symlink chain is cyclic or too deep' >&2; return 1; }
            print_project_protection_target "$parent" "$project" || return 1
            target=$(readlink -- "$current" && printf '.') || return 1
            [[ "$target" = *$'\n.' ]] || return 1
            target=${target%$'\n.'}
            reject_control_characters 'protected symlink target' "$target"
            case "$target" in
                /*) current=/; target=${target#/} ;;
                *) current=$parent ;;
            esac
            pending=$target${rest:+/$rest}
        elif [[ ! -e "$current" ]]; then
            printf 'Error: protected symlink target does not exist: %s\n' "$current" >&2
            return 1
        elif [[ "$directory_component" = true && ! -d "$current" ]]; then
            printf 'Error: protected symlink traverses a non-directory: %s\n' "$current" >&2
            return 1
        fi
    done
    [[ -f "$current" || -d "$current" ]] || {
        echo 'Error: protected symlink target is not a regular file or directory' >&2
        return 1
    }
    print_project_protection_target "$current" "$project"
}

# Print the canonical project-relative spelling of an existing path. Return
# 1 for an outside path and 2 when containment cannot be established. Callers
# may omit an outside input's project mount, but must not ignore a failed read.
canonical_project_relative_path() {
    local candidate project_abs candidate_abs

    candidate="$1"
    project_abs=$(realpath -- "$PROJECT_DIR" 2>/dev/null) || return 2
    candidate_abs=$(realpath -- "$candidate" 2>/dev/null) || return 2
    [ -e "$candidate_abs" ] || return 2
    [[ "$candidate_abs" == "$project_abs/"* ]] || return 1
    printf '%s\n' "${candidate_abs#"$project_abs"/}"
}

validate_project_mount_path_lexical() {
    local path

    path="$1"
    case "$path" in
        "") return 1 ;;
        /*) return 1 ;;
        *//* ) return 1 ;;
        .|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
        *:*) return 1 ;;
        */) return 1 ;;
    esac
}

check_project_path_no_symlinks() {
    local relative current component
    local -a components

    relative="$1"
    current=$(realpath -- "$PROJECT_DIR" 2>/dev/null) || return 1
    IFS='/' read -ra components <<< "$relative"
    for component in "${components[@]}"; do
        current="$current/$component"
        [ ! -L "$current" ] || return 1
    done
}

project_path_type() {
    local path

    path="$1"
    if [ -f "$path" ]; then
        printf 'file\n'
    elif [ -d "$path" ]; then
        printf 'directory\n'
    else
        printf 'special\n'
    fi
}

check_project_mount_path() {
    local path candidate relative type

    path="$1"
    validate_project_mount_path_lexical "$path" || return 1
    candidate="$(realpath -- "$PROJECT_DIR" 2>/dev/null)/$path"
    check_project_path_no_symlinks "$path" || return 3
    [ -e "$candidate" ] || return 2
    relative=$(canonical_project_relative_path "$candidate") || return 4
    type=$(project_path_type "$candidate")
    [ "$type" != special ] || return 5
    printf '%s\n' "$relative"
}

check_readonly_path() {
    local path result status

    path="$1"
    status=0
    result=$(check_project_mount_path "$path") || status=$?
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$result"
        return 0
    fi
    case "$status" in
        1) die "invalid READONLY_PATHS path '$path' (use a non-empty project-relative path without dot segments, colons, or a trailing slash)" ;;
        2) die "READONLY_PATHS path does not exist: $path" ;;
        3) die "READONLY_PATHS path contains a symlink: $path" ;;
        4) die "READONLY_PATHS path resolves outside the project: $path" ;;
        5) die "READONLY_PATHS path is not a regular file or directory: $path" ;;
    esac
}

# ASCII control characters are never valid in a configuration value or in a
# path jailbox encodes into a TAB- or newline-delimited record. NUL cannot
# appear in a Bash string, so this predicate covers every byte the framing
# cannot represent unambiguously.
contains_control_character() {
    local value LC_ALL=C

    value="$1"
    [[ "$value" =~ [$'\x01'-$'\x1f'$'\x7f'] ]]
}

# Refuse a path before it reaches delimiter-based classification or digest
# serialization. The offending value is deliberately not echoed back: it is
# exactly the string whose control characters would corrupt that output.
reject_control_characters() {
    local description

    description="$1"
    if contains_control_character "$2"; then
        die "$description path contains an ASCII control character"
    fi
}

check_path_no_symlinks() {
    local path current component
    local -a components

    path="$1"
    case "$path" in
        /*) current=/ ;;
        *) current="$PWD" ;;
    esac
    IFS='/' read -ra components <<< "$path"
    for component in "${components[@]}"; do
        [ -z "$component" ] && continue
        [ "$component" = . ] && continue
        if [ "$component" = .. ]; then
            current=$(dirname "$current")
            continue
        fi
        current="${current%/}/$component"
        [ ! -L "$current" ] || return 1
    done
}

classify_trusted_file() {
    local path description canonical relative status=0

    path="$1"
    description="$2"
    reject_control_characters "$description" "$path"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -f "$path" ] || die "$description path is not a regular file: $path"
    [ -r "$path" ] || die "$description path is not readable: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    reject_control_characters "canonical $description" "$canonical"
    relative=""
    relative=$(canonical_project_relative_path "$canonical") || status=$?
    case "$status" in
        0) ;;
        1) relative="" ;;
        *) die "cannot establish project containment for $description path: $path" ;;
    esac
    printf '%s\t%s\n' "$canonical" "$relative"
}

classify_trusted_directory() {
    local path description canonical

    path="$1"
    description="$2"
    reject_control_characters "$description" "$path"
    check_path_no_symlinks "$path" || die "$description path contains a symlink: $path"
    [ -e "$path" ] || die "$description path does not exist: $path"
    [ -d "$path" ] || die "$description path is not a directory: $path"
    [[ -r "$path" && -x "$path" ]] || die "$description path is not accessible: $path"
    canonical=$(realpath -- "$path") || die "cannot canonicalize $description path: $path"
    reject_control_characters "canonical $description" "$canonical"
    printf '%s\n' "$canonical"
}
