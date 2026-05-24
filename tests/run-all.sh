#!/bin/bash
# Run all jailbox test suites in fast-fail order.
#
# Ordering:
#   1. unit tests        pure shell, no Podman
#   2. integration tests build/run containers, no editor GUI
#   3. e2e tests         full jailbox workflow and editor smoke
#
# Suites that require podman are skipped automatically when podman is absent.
# The editor suite is skipped when neither codium nor code is in PATH.
#
# Usage: tests/run-all.sh [--unit-only] [--skip-editor] [--help]
#
#   --unit-only     Run only the unit tests (no podman required)
#   --skip-editor   Skip the editor smoke test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

UNIT_ONLY=false
SKIP_EDITOR=false

SUITES_PASSED=0
SUITES_FAILED=0
SUITES_SKIPPED=0

# ── helpers ───────────────────────────────────────────────────────────────────

die()  { echo "Error: $*" >&2; exit 1; }

suite_pass()  {
    printf '\n✅ PASS  %s\n' "$1"
    SUITES_PASSED=$((SUITES_PASSED + 1))
}

suite_fail()  {
    printf '\n❌ FAIL  %s\n' "$1"
    SUITES_FAILED=$((SUITES_FAILED + 1))
}

suite_skip()  {
    printf '⏭  skip  %s  (%s)\n' "$1" "$2"
    SUITES_SKIPPED=$((SUITES_SKIPPED + 1))
}

have_podman() { command -v podman >/dev/null 2>&1; }
have_editor() {
    command -v codium >/dev/null 2>&1 || command -v code >/dev/null 2>&1
}

have_display() {
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

run_suite() {
    local label="$1"; shift
    printf '\n══ %s ══\n' "$label"
    if "$@"; then
        suite_pass "$label"
    else
        suite_fail "$label"
        echo ""
        echo "Stopping: fix $label before running later suites." >&2
        print_summary
        exit 1
    fi
}

print_summary() {
    echo ""
    echo "──────────────────────────────────────────────────────────────────────"
    printf 'Suites: %d passed' "$SUITES_PASSED"
    [[ "$SUITES_FAILED"  -gt 0 ]] && printf ', %d failed'  "$SUITES_FAILED"
    [[ "$SUITES_SKIPPED" -gt 0 ]] && printf ', %d skipped' "$SUITES_SKIPPED"
    printf '\n'
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--unit-only] [--skip-editor] [--help]

Run all jailbox test suites in fast-fail order.

Options:
  --unit-only     Run only the two unit tests (no podman required)
  --skip-editor   Skip the editor smoke test
  --help          Show this help

Suites (in order):
  unit/config-parser        host/public-api.sh config parsing
  unit/downloader-proxy      container/downloader-proxy-manager.sh
  integration/wrapper-images        build images and run container/runtime/security assertions
  e2e/headless              full jailbox CLI end-to-end, headless editor stub
  e2e/editor-smoke          launch VSCodium/VS Code and verify Remote SSH task
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --unit-only)    UNIT_ONLY=true ;;
        --skip-editor)  SKIP_EDITOR=true ;;
        --help|-h)      usage; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

# ── main ──────────────────────────────────────────────────────────────────────

echo "jailbox test runner"
echo "Working directory: $JAILBOX_DIR"
echo ""

# 1. Unit tests: pure shell, no Podman.
run_suite "unit/config-parser" bash "$SCRIPT_DIR/unit/config-parser.sh"
run_suite "unit/downloader-proxy" bash "$SCRIPT_DIR/unit/downloader-proxy.sh"

if [[ "$UNIT_ONLY" == true ]]; then
    echo ""
    echo "Stopping after unit tests (--unit-only)."
    print_summary
    exit 0
fi

# 2. Integration tests: Podman required, no editor GUI. The images suite also
#    runs runtime/security assertions during its existing container launches.
if ! have_podman; then
    suite_skip "integration/wrapper-images" "podman not found"
    suite_skip "e2e/headless"       "podman not found"
    suite_skip "e2e/editor-smoke"   "podman not found"
    print_summary
    exit 0
fi

run_suite "integration/wrapper-images" bash "$SCRIPT_DIR/integration/wrapper-images.sh"

# 3. E2E tests: full jailbox workflow. Headless uses an editor stub; editor
#    smoke requires a real VSCodium/VS Code CLI.
run_suite "e2e/headless" bash "$SCRIPT_DIR/e2e/headless.sh"

if [[ "$SKIP_EDITOR" == true ]]; then
    suite_skip "e2e/editor-smoke" "--skip-editor"
elif ! have_editor; then
    suite_skip "e2e/editor-smoke" "neither codium nor code found in PATH"
elif ! have_display; then
    suite_skip "e2e/editor-smoke" "no graphical display session found"
else
    run_suite "e2e/editor-smoke" bash "$SCRIPT_DIR/e2e/editor-smoke.sh"
fi

print_summary
[[ "$SUITES_FAILED" -eq 0 ]]
