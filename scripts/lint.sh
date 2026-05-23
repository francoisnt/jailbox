#!/usr/bin/env bash
# Run shellcheck on all shell scripts in the repository.
#
# Usage: scripts/lint.sh [--format <fmt>]
# Flags are forwarded to shellcheck.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

# jailbox (bash) — checked with --external-sources so shellcheck follows every
# sourced lib/*.sh file in context, resolving cross-file variable references.
echo "shellcheck: jailbox (+ sourced lib/*.sh)"
shellcheck --external-sources --shell=bash "$@" jailbox

# Standalone bash scripts
echo "shellcheck: scripts/ and tests/"
shellcheck --shell=bash "$@" \
    scripts/build-tarball.sh \
    scripts/public-api-diff.sh \
    scripts/release.sh \
    install.sh \
    tests/config-parser.sh \
    tests/e2e-headless.sh \
    tests/editor-smoke.sh \
    tests/integration-images.sh \
    tests/proxy-bootstrap.sh \
    tests/run-all.sh

# Bash scripts in install/ (bash justified: container always installs bash)
echo "shellcheck: install/manage-proxy-bootstrap.sh"
shellcheck --shell=bash "$@" \
    install/manage-proxy-bootstrap.sh

# POSIX sh scripts
echo "shellcheck: install/ and jailbox-start"
shellcheck --shell=sh "$@" \
    install/setup.sh \
    jailbox-start

echo "shellcheck: all clean"
