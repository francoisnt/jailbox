#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/prerequisites.sh
source "$ROOT/src/host/prerequisites.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

require_host_realpath
require_host_sort
# Check every required realpath option, including a plausible result on failure.
for option in -e -m --relative-to=/; do
    (
        realpath() {
            if [[ $1 = "$option" ]]; then printf '/\n'; return 42; fi
            command realpath "$@"
        }
        if require_host_realpath; then fail 'incompatible realpath accepted'; fi
    ) > "$tmp/out" 2>&1
    grep -Fq 'brew install coreutils' "$tmp/out"
    # shellcheck disable=SC2016 # Instructions must preserve the user's PATH expansion.
    grep -Fq 'libexec/gnubin:$PATH' "$tmp/out"
done
(
    sort() { printf 'a\0b\0'; return 42; }
    if require_host_sort; then fail 'failed sort with valid output accepted'; fi
) > "$tmp/out" 2>&1
grep -Fq 'sort supporting -z' "$tmp/out"
(
    realpath() { printf '/wrong\n'; }
    if require_host_realpath; then fail 'incorrect realpath result accepted'; fi
) > "$tmp/out" 2>&1
(
    sort() { cat; }
    if require_host_sort; then fail 'unsorted records accepted'; fi
) > "$tmp/out" 2>&1
(
    if PATH=$tmp require_host_realpath; then fail 'missing realpath accepted'; fi
) > "$tmp/out" 2>&1
grep -Fq 'realpath supporting' "$tmp/out"

mkdir "$tmp/tools"
export JAILBOX_INSTALL_DIR="$tmp/share/jailbox" JAILBOX_BIN_DIR="$tmp/bin"
installer_bash=$(command -v bash)
if [[ $(uname -s) = Darwin ]]; then installer_bash=/bin/bash; fi
# The installer must diagnose its directly sourced helper before any target work.
mkdir -p "$tmp/bundle/host" "$tmp/bundle/container"
cp "$ROOT/src/"{install.sh,jailbox,public-api.sh} "$tmp/bundle/"
if "$installer_bash" "$tmp/bundle/install.sh" > "$tmp/out" 2>&1; then
    fail 'incomplete bundle accepted'
fi
grep -Fq 'installer bundle is missing required file: host/prerequisites.sh' "$tmp/out"
[[ ! -e "$tmp/share" && ! -e "$tmp/bin" ]]
for utility in realpath sort; do
    ln -s "$(type -P false)" "$tmp/tools/$utility"
    if PATH="$tmp/tools:$PATH" "$installer_bash" "$ROOT/src/install.sh" > "$tmp/out" 2>&1; then
        fail 'installation accepted incompatible utility'
    fi
    grep -Fq "$utility supporting" "$tmp/out"
    [[ ! -e "$tmp/share" && ! -e "$tmp/bin" ]]
    rm "$tmp/tools/$utility"
done
"$installer_bash" "$ROOT/src/install.sh" > "$tmp/out" 2>&1
printf 'preserved\n' > "$JAILBOX_INSTALL_DIR/keep"
ln -s "$(type -P false)" "$tmp/tools/realpath"
if PATH="$tmp/tools:$PATH" "$installer_bash" "$ROOT/src/install.sh" > "$tmp/out" 2>&1; then
    fail 'update accepted incompatible realpath'
fi
[[ $(cat "$JAILBOX_INSTALL_DIR/keep") = preserved ]]
cmp "$ROOT/src/jailbox" "$JAILBOX_INSTALL_DIR/jailbox"
PATH="$tmp/tools:$PATH" "$installer_bash" "$ROOT/src/install.sh" --help > "$tmp/out"
PATH="$tmp/tools:$PATH" "$installer_bash" "$ROOT/src/install.sh" --uninstall > "$tmp/out"
[[ ! -e "$JAILBOX_INSTALL_DIR" ]]

# Public runtime validation reports setup instructions before interpreting policy.
if PATH="$tmp/tools:$PATH" "$ROOT/src/jailbox" validate > "$tmp/out" 2>&1; then
    fail 'runtime accepted incompatible realpath'
fi
grep -Fq 'realpath supporting' "$tmp/out"
# Launch must stop at preflight, before any Podman operation.
ln -s "$(type -P false)" "$tmp/tools/podman"
if PATH="$tmp/tools:$PATH" "$ROOT/src/jailbox" up > "$tmp/out" 2>&1; then
    fail 'launch accepted incompatible realpath'
fi
grep -Fq 'realpath supporting' "$tmp/out"
rm "$tmp/tools/realpath"
ln -s "$(type -P false)" "$tmp/tools/sort"
if PATH="$tmp/tools:$PATH" "$ROOT/src/jailbox" up > "$tmp/out" 2>&1; then
    fail 'launch accepted incompatible sort'
fi
grep -Fq 'sort supporting -z' "$tmp/out"
# Validation and every attachment consumer share the same capability boundary.
mkdir -p "$tmp/project/protected"
for command in validate connection-info exec; do
    args=(); [[ $command != exec ]] || args=(true)
    if (cd "$tmp/project" && PATH="$tmp/tools:$PATH" \
        JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev JAILBOX_CONFIG_READONLY_PATHS_0=protected \
        XDG_STATE_HOME="$tmp/state" "$ROOT/src/jailbox" "$command" "${args[@]}") > "$tmp/out" 2> "$tmp/err"; then
        fail "$command accepted incompatible sort"
    fi
    [[ ! -s "$tmp/out" && ! -e "$tmp/state" ]]
    grep -Fq 'sort supporting -z' "$tmp/err"
    grep -Fq 'brew install coreutils' "$tmp/err"
done
(
    # shellcheck source=src/host/core/checks/host.sh
    source "$ROOT/src/host/core/checks/host.sh"
    # shellcheck source=src/host/core/checks/attachment.sh
    source "$ROOT/src/host/core/checks/attachment.sh"
    # shell uses this same boundary with errexit suppressed by its caller.
    if PATH="$tmp/tools:$PATH" validate_attachment; then fail 'attachment accepted incompatible sort'; fi
) > "$tmp/out" 2>&1
grep -Fq 'sort supporting -z' "$tmp/out"
(
    # A prerequisite may report failure by returning, rather than exiting.
    # shellcheck source=src/host/core/checks/host.sh
    source "$ROOT/src/host/core/checks/host.sh"
    require_command() { [[ $1 != podman ]]; }
    if host_preflight; then fail 'conditional preflight discarded prerequisite failure'; fi
)
printf 'PASS: host utility capabilities, setup guidance, and installation preservation\n'
