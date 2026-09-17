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

# Bash scripts in container/ (bash justified: container always installs bash)
echo "shellcheck: container Bash scripts"
shellcheck --shell=bash "$@" \
    container/downloader-proxy-manager.sh \
    container/jailbox-exec-argv \
    container/write-editor-settings.sh \
    container/validate-session.sh

# POSIX sh scripts
echo "shellcheck: container/ and container/entrypoint.sh"
shellcheck --shell=sh "$@" \
    container/setup.sh \
    container/entrypoint.sh

echo "shellcheck: all clean"
