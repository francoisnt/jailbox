#!/bin/bash
# Run all jailbox test suites in fast-fail order.
#
# Ordering rationale — most likely to fail first:
#   1. proxy-bootstrap  unit test  (pure shell, covers recently added code)
#   2. config-parser    unit test  (pure shell, covers core parsing logic)
#   3. integration-images          (builds wrapper image; exercises setup.sh)
#   4. e2e-headless                (full jailbox CLI; needs images from step 3)
#   5. editor-smoke                (requires a running editor; skipped if absent)
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
have_editor() { command -v codium >/dev/null 2>&1 || command -v code >/dev/null 2>&1; }

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
  proxy-bootstrap    unit test — install/manage-proxy-bootstrap.sh
  config-parser      unit test — lib/public-api.sh config parsing
  integration-images build jailbox-test-* wrapper images and run assertions
  e2e-headless       full jailbox CLI end-to-end (headless)
  editor-smoke       launch VSCodium/VS Code and verify Remote SSH task
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

# 1. proxy-bootstrap unit test (pure shell; most recently added code)
run_suite "proxy-bootstrap" bash "$SCRIPT_DIR/proxy-bootstrap.sh"

# 2. config-parser unit test (pure shell; covers core parsing invariants)
run_suite "config-parser" bash "$SCRIPT_DIR/config-parser.sh"

if [[ "$UNIT_ONLY" == true ]]; then
    echo ""
    echo "Stopping after unit tests (--unit-only)."
    print_summary
    exit 0
fi

# 3. integration-images (podman required; builds jailbox-test-* images used by
#    e2e and editor suites — must run before them)
if ! have_podman; then
    suite_skip "integration-images" "podman not found"
    suite_skip "e2e-headless"       "podman not found"
    suite_skip "editor-smoke"       "podman not found"
    print_summary
    exit 0
fi

run_suite "integration-images" bash "$SCRIPT_DIR/integration-images.sh"

# 4. e2e-headless (podman required; runs full jailbox CLI against the images
#    built in the previous step)
run_suite "e2e-headless" bash "$SCRIPT_DIR/e2e-headless.sh"

# 5. editor-smoke (podman + editor required; most environment-specific)
if [[ "$SKIP_EDITOR" == true ]]; then
    suite_skip "editor-smoke" "--skip-editor"
elif ! have_editor; then
    suite_skip "editor-smoke" "neither codium nor code found in PATH"
else
    run_suite "editor-smoke" bash "$SCRIPT_DIR/editor-smoke.sh"
fi

print_summary
[[ "$SUITES_FAILED" -eq 0 ]]
