#!/usr/bin/env bash
# Run shellcheck on all shell scripts in the repository.
#
# Usage: scripts/lint.sh [--format <fmt>]
# Flags are forwarded to shellcheck.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"

# jailbox (bash) — checked with --external-sources so shellcheck follows every
# sourced host/*.sh file in context, resolving cross-file variable references.
echo "shellcheck: jailbox (+ sourced host/*.sh)"
shellcheck --external-sources --shell=bash "$@" jailbox

# Standalone bash scripts
echo "shellcheck: scripts/ and tests/"
shellcheck --external-sources --shell=bash "$@" \
    scripts/build-tarball.sh \
    scripts/canary-report.sh \
    scripts/public-api-diff.sh \
    scripts/release.sh \
    scripts/resolve-latest-versions.sh \
    install.sh \
    tests/ci/setup-common.sh \
    tests/ci/setup-linux.sh \
    tests/ci/setup-macos.sh \
    tests/portable/smoke.sh \
    tests/unit/config-parser.sh \
    tests/unit/downloader-proxy.sh \
    tests/unit/network.sh \
    tests/unit/ssh-config.sh \
    tests/lib/run-meta.sh \
    tests/integration/wrapper-images.sh \
    tests/integration/runtime-security.sh \
    tests/e2e/headless.sh \
    tests/e2e/editor-smoke.sh \
    tests/run

# Bash scripts in container/ (bash justified: container always installs bash)
echo "shellcheck: container/downloader-proxy-manager.sh"
shellcheck --shell=bash "$@" \
    container/downloader-proxy-manager.sh

# POSIX sh scripts
echo "shellcheck: container/ and container/entrypoint.sh"
shellcheck --shell=sh "$@" \
    container/setup.sh \
    container/entrypoint.sh

echo "shellcheck: all clean"
