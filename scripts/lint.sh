#!/usr/bin/env bash
# Run shellcheck on all shell scripts in the repository.
#
# Usage: scripts/lint.sh [--format <fmt>]
# Flags are forwarded to shellcheck.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

# jailbox (bash) — checked with --external-sources so shellcheck follows every
# sourced host/*.sh file in context and reports its findings too.
echo "shellcheck: jailbox (+ sourced host/*.sh)"
shellcheck --check-sourced --external-sources --shell=bash "$@" jailbox

# Standalone bash scripts. Discover repository tooling and tests so adding a
# new suite cannot silently leave it outside ShellCheck coverage.
echo "shellcheck: scripts/ and tests/"
bash_scripts=(install.sh tests/run)
while IFS= read -r script; do
    bash_scripts+=("$script")
done < <(find scripts tests -type f -name '*.sh' ! -path 'tests/run' -print | sort)
shellcheck --external-sources --shell=bash "$@" "${bash_scripts[@]}"

# Discover nested and extensionless container scripts. The shebang owns the
# dialect; a .sh file without a supported shebang must not silently escape.
container_bash=()
container_sh=()
while IFS= read -r script; do
    IFS= read -r interpreter < "$script" || interpreter=""
    case "$interpreter" in
        '#!/bin/bash'|'#!/usr/bin/env bash') container_bash+=("$script") ;;
        '#!/bin/sh'|'#!/usr/bin/env sh') container_sh+=("$script") ;;
        *)
            if [[ "$script" = *.sh ]]; then
                printf 'Error: unsupported shell shebang in %s\n' "$script" >&2
                exit 1
            fi
            ;;
    esac
done < <(find container -type f -print | sort)
echo "shellcheck: container Bash scripts"
if [[ -n ${container_bash[*]-} ]]; then
    shellcheck --shell=bash "$@" "${container_bash[@]}"
fi
echo "shellcheck: container POSIX sh scripts"
if [[ -n ${container_sh[*]-} ]]; then
    shellcheck --shell=sh "$@" "${container_sh[@]}"
fi

echo "shellcheck: all clean"
