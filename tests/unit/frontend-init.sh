#!/bin/bash
# shellcheck disable=SC2030,SC2031 # API mutations intentionally stay in subshells.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/frontend/file-policy.sh
source "$ROOT/src/host/frontend/file-policy.sh"
# shellcheck source=src/host/frontend/init.sh
source "$ROOT/src/host/frontend/init.sh"
TEMPLATE=$ROOT/src/host/frontend/jailbox.conf.template
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+rwX "$TMP"; rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

check_template_defaults() {
    local config=$1 entry key
    # shellcheck disable=SC2034 # Consumed through the mapping validator's nameref.
    local -a members=("${CONFIG_SCALAR_KEYS[@]}" "${CONFIG_ARRAY_KEYS[@]}" "${FRONTEND_SCALAR_KEYS[@]}")
    parse_config_file "$config"
    public_api_validate_mapping 'template settings' members FRONTEND_VALUES allow-empty
    for entry in "${CONFIG_DEFAULTS[@]}" "${FRONTEND_DEFAULTS[@]}"; do
        key=${entry%%=*}
        [[ ${FRONTEND_VALUES[$key]} == "${entry#*=}" ]] || fail "wrong default for $key"
    done
    grep -Fxq '# OR build a development image.' "$config" || fail 'missing image/build alternative'
}

# Check the shipped file itself, independently of the init implementation.
check_template_defaults "$TEMPLATE"

# No Podman, SSH, editor, or public core executable is available in this PATH.
mkdir "$TMP/bin"
for tool in mktemp ln rm cat; do
    ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
for mode in 0022 0002; do
    (
        umask "$mode"
        local_project=$TMP/project-$mode
        mkdir -p "$local_project/.git/hooks" "$local_project/.github/workflows"
        # An unreadable directory is an existing candidate; detection must not
        # read its contents. No real dotenv file is opened by this suite.
        mkdir "$local_project/.env"
        chmod 000 "$local_project/.env"
        touch "$local_project/.git/config" "$local_project/AGENTS.md" "$local_project/CLAUDE.md"
        chmod 600 "$local_project/AGENTS.md" "$local_project/CLAUDE.md"
        PATH="$TMP/bin" init_project_config "$local_project" > "$TMP/out"
        expected=$(cat "$local_project/jailbox.conf")
        suggestions=$(grep -E '^# (\.env|\.git/hooks|\.git/config|AGENTS.md|CLAUDE.md|\.github/workflows)$' "$local_project/jailbox.conf")
        [[ $suggestions == $'# .env\n# .git/hooks\n# .git/config\n# AGENTS.md\n# CLAUDE.md\n# .github/workflows' ]] || fail 'suggestion order'
        [[ $(LC_ALL=C ls -l "$local_project/jailbox.conf") == -rw-------* ]] || fail 'private file mode'
        check_template_defaults "$local_project/jailbox.conf"
        # Enabling suggestions edits one assignment, with no duplicate keys.
        sed 's/^READONLY_PATHS=$/READONLY_PATHS=AGENTS.md,CLAUDE.md/' "$local_project/jailbox.conf" > "$local_project/selected.conf"
        load_file_policy "$local_project" "$local_project/selected.conf"
        [[ ${FRONTEND_VALUES[READONLY_PATHS]} == AGENTS.md,CLAUDE.md ]]
        if init_project_config "$local_project" > "$TMP/out" 2> "$TMP/err"; then fail 'overwrote file'; fi
        grep -q 'already exists' "$TMP/err"
        [[ $(cat "$local_project/jailbox.conf") == "$expected" ]]
        for kind in directory symlink fifo; do
            other=$TMP/$mode-$kind
            mkdir "$other"
            case "$kind" in
                directory) mkdir "$other/jailbox.conf" ;;
                symlink) ln -s absent "$other/jailbox.conf" ;;
                fifo) mkfifo "$other/jailbox.conf" ;;
            esac
            if init_project_config "$other" > "$TMP/out" 2> "$TMP/err"; then fail "overwrote $kind"; fi
            grep -q 'already exists' "$TMP/err"
            [[ ! -s "$TMP/out" ]]
        done
        empty=$TMP/empty-$mode
        mkdir "$empty"
        init_project_config "$empty" > "$TMP/out"
        check_template_defaults "$empty/jailbox.conf"
        if grep -Eq '^# (\.env|\.git/hooks|\.git/config|AGENTS.md|CLAUDE.md|\.github/workflows)$' "$empty/jailbox.conf"; then
            fail 'absent suggestion stubs'
        fi
    )
done

# The template contract test must catch new declarations and changed defaults.
for category in scalar array frontend; do
    (
        case "$category" in
            scalar) CONFIG_SCALAR_KEYS+=(SAMPLE); CONFIG_DEFAULTS+=(SAMPLE=) ;;
            array) CONFIG_ARRAY_KEYS+=(SAMPLE); CONFIG_DEFAULTS+=(SAMPLE=) ;;
            frontend) FRONTEND_SCALAR_KEYS+=(SAMPLE); FRONTEND_DEFAULTS+=(SAMPLE=) ;;
        esac
        if (check_template_defaults "$TEMPLATE") > "$TMP/out" 2> "$TMP/err"; then fail "omitted $category key"; fi
        grep -Fq "template settings: missing mapping 'SAMPLE'" "$TMP/err"
    )
done
for key in MEMORY_LIMIT EDITOR; do
    (
        if [[ $key == EDITOR ]]; then
            FRONTEND_DEFAULTS=(EDITOR=code)
        else
            for index in "${!CONFIG_DEFAULTS[@]}"; do
                [[ ${CONFIG_DEFAULTS[index]} != MEMORY_LIMIT=* ]] || CONFIG_DEFAULTS[index]=MEMORY_LIMIT=8g
            done
        fi
        if (check_template_defaults "$TEMPLATE") > "$TMP/out" 2> "$TMP/err"; then fail "missed changed $key default"; fi
        grep -Fq "wrong default for $key" "$TMP/err"
    )
done

# Exercise required operations under conditional invocation (errexit disabled
# throughout the call tree), while preserving caller traps/options/directory.
publication_failures() (
    local mode fault fault_project before_traps before_flags before_pwd before_options
    trap ':' HUP INT TERM
    before_traps=$(trap -p)
    before_flags=$-
    before_pwd=$PWD
    before_options=$(set +o)
    # shellcheck disable=SC2329 # Fault wrappers invoked by sourced functions.
    mktemp() {
        [[ $fault != mktemp ]] || return 41
        command mktemp "$@"
        [[ $fault != allocated ]] || return 42
    }
    # shellcheck disable=SC2329
    cat() {
        if [[ $fault == write && ${2:-} == */jailbox.conf.template ]]; then
            printf 'partial\n' || return $?
            return 42
        fi
        command cat "$@"
    }
    # shellcheck disable=SC2329
    ln() {
        case "$fault" in
            publish|cleanup) return 43 ;;
            directory) mkdir "${3}" || return $? ;;
            symlink) command ln -s "$fault_project/other" "${3}" || return $? ;;
            HUP|INT|TERM) kill -"$fault" "$BASHPID"; return 44 ;;
        esac
        command ln "$@"
    }
    # shellcheck disable=SC2329
    rm() { [[ $fault != cleanup ]] || return 45; command rm "$@"; }
    for mode in 0022 0002; do
        umask "$mode"
        for fault in mktemp allocated write publish directory symlink HUP INT TERM cleanup; do
            fault_project=$TMP/failure-$mode-$fault
            mkdir -p "$fault_project/other"
            chmod 700 "$fault_project" "$fault_project/other"
            printf 'preserve\n' > "$fault_project/unrelated"
            if init_project_config "$fault_project" > "$TMP/out" 2> "$TMP/err"; then fail "accepted $fault failure"; fi
            [[ ! -s "$TMP/out" ]] || fail "success output after $fault"
            [[ $(cat "$fault_project/unrelated") == preserve ]]
            [[ $(trap -p) == "$before_traps" && $- == "$before_flags" && $PWD == "$before_pwd" && $(set +o) == "$before_options" && $(umask) == "$mode" ]] || fail 'caller state changed'
            case "$fault" in
                directory) [[ -d "$fault_project/jailbox.conf" ]] ;;
                symlink) [[ -L "$fault_project/jailbox.conf" ]] ;;
                *) [[ ! -e "$fault_project/jailbox.conf" ]] ;;
            esac
            if [[ $fault == cleanup ]]; then
                grep -q 'could not clean temporary' "$TMP/err"
                grep -q 'could not publish' "$TMP/err"
            else
                [[ -z $(find "$fault_project" -name '.jailbox.conf.tmp.*' -print) ]] || fail "temporary files after $fault"
            fi
        done
    done
)
publication_failures
project=$TMP/concurrent
mkdir "$project"
init_project_config "$project" > "$TMP/first" 2>&1 &
first=$!
init_project_config "$project" > "$TMP/second" 2>&1 &
second=$!
successes=0
if wait "$first"; then successes=$((successes + 1)); fi
if wait "$second"; then successes=$((successes + 1)); fi
[[ $successes == 1 && -f "$project/jailbox.conf" && -z $(find "$project" -name '.jailbox.conf.tmp.*' -print) ]] || fail 'concurrent publication'
printf 'PASS: prepared local init, suggestions, no-overwrite, and publication failures under both umasks\n'
