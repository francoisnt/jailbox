#!/bin/bash
# Run the editor gate in two steps, so CI can tell a setup failure from a
# failing editor test.
#
# Usage: tests/ci/editor-gate.sh setup [UPDATE...]
#          Apply editor updates (KEY=VALUE pairs, see scripts/apply-updates.sh)
#          to this checkout, then install the editors and their extensions.
#        tests/ci/editor-gate.sh test
#          Run tests/run editor for $JAILBOX_EDITOR.
#
# The daily published-release editor check runs an older release's copy of this script,
# so keep its path, subcommands, and update arguments stable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_editors() {
    if (($#)); then
        bash "$ROOT_DIR/scripts/apply-updates.sh" "$@" || return $?
    fi
    bash "$ROOT_DIR/tests/ci/setup-linux.sh" --with-editors
}

case "${1-}" in
    setup)
        shift
        # The workflow uploads testlog/*/editor/ even if setup fails before
        # tests/run creates its own log directory.
        # shellcheck source=tests/lib/logging.sh
        source "$ROOT_DIR/tests/lib/logging.sh"
        setup_logs="$ROOT_DIR/testlog/ci-setup/editor"
        mkdir -p "$setup_logs"
        setup_editors "$@" 2>&1 | test_timestamp_stream | tee "$setup_logs/setup.log"
        ;;
    test)
        (($# == 1)) || { echo 'usage: editor-gate.sh test' >&2; exit 2; }
        bash "$ROOT_DIR/tests/run" editor
        ;;
    *)
        echo 'usage: editor-gate.sh setup [UPDATE...] | test' >&2
        exit 2
        ;;
esac
