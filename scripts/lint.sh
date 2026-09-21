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
shellcheck --check-sourced --external-sources --shell=bash "$@" src/jailbox

# Standalone bash scripts. Discover repository tooling and tests so adding a
# new suite cannot silently leave it outside ShellCheck coverage.
echo "shellcheck: scripts/, tests/, and host modules"
bash_scripts=(install.sh tests/run)
while IFS= read -r script; do
    bash_scripts+=("$script")
done < <(find scripts tests -type f -name '*.sh' ! -path 'tests/run' -print | sort)
shellcheck --external-sources --shell=bash "$@" "${bash_scripts[@]}"

# Modules are checked in entrypoint context above. Also discover every module,
# including new unreferenced files; standalone module state/callbacks are shared.
host_scripts=(src/public.sh)
while IFS= read -r script; do host_scripts+=("$script"); done < <(find src/host -type f -name '*.sh' -print | sort)
if [[ -n ${host_scripts[*]-} ]]; then
    shellcheck --external-sources --shell=bash --exclude=SC2034,SC2329 "$@" "${host_scripts[@]}"
fi

# shellcheck source=scripts/lib/container-shells.sh
source "$SCRIPT_DIR/lib/container-shells.sh"
collect_container_shells src
echo "shellcheck: container Bash scripts"
if [[ -n ${container_bash[*]-} ]]; then
    shellcheck --shell=bash "$@" "${container_bash[@]}"
fi
echo "shellcheck: container POSIX sh scripts"
if [[ -n ${container_sh[*]-} ]]; then
    shellcheck --shell=sh "$@" "${container_sh[@]}"
fi

echo "shellcheck: all clean"
