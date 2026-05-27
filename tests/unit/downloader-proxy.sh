#!/bin/bash
# Unit tests for container/downloader-proxy-manager.sh.
#
# Tests are run with a temporary HOME directory so the script operates on
# isolated dotfiles without touching the developer's actual home.
#
# Usage: tests/unit/downloader-proxy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANAGE_PROXY="$JAILBOX_DIR/container/downloader-proxy-manager.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

run_script() {
    local home_dir="$1"; shift
    HOME="$home_dir" bash "$MANAGE_PROXY" "$@"
}

assert_exists() {
    local name="$1" file="$2"
    if [[ -f "$file" ]]; then pass "$name"; else fail "$name (missing: $file)"; fi
}

assert_absent() {
    local name="$1" file="$2"
    if [[ ! -f "$file" ]]; then pass "$name"; else fail "$name (unexpectedly present: $file)"; fi
}

assert_contains() {
    local name="$1" file="$2" pattern="$3"
    if grep -Fq "$pattern" "$file"; then
        pass "$name"
    else
        fail "$name (pattern not found: $pattern)"
    fi
}

assert_not_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -Fq "$pattern" "$file"; then
        pass "$name"
    else
        fail "$name (pattern unexpectedly found: $pattern)"
    fi
}

assert_mode() {
    local name="$1" file="$2" expected="$3"
    local actual
    if actual=$(stat -c '%a' "$file" 2>/dev/null); then
        :
    else
        actual=$(stat -f '%Lp' "$file")
    fi
    if [[ "$actual" == "$expected" ]]; then
        pass "$name"
    else
        fail "$name (expected mode $expected, got $actual)"
    fi
}

assert_count() {
    local name="$1" file="$2" pattern="$3" expected="$4"
    local actual
    actual=$(grep -Fc "$pattern" "$file" || true)
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name (expected $expected occurrences of '$pattern', got $actual)"
    fi
}

# ── enable: new files ─────────────────────────────────────────────────────────

test_enable_creates_curlrc() {
    local d; d=$(mktemp -d)
    run_script "$d" enable "http://proxy.test:8888"
    assert_exists   "enable: curlrc created"              "$d/.curlrc"
    assert_contains "enable: curlrc proxy directive"      "$d/.curlrc" 'proxy = "http://proxy.test:8888"'
    assert_contains "enable: curlrc begin marker"         "$d/.curlrc" '# >>> jailbox managed proxy >>>'
    assert_contains "enable: curlrc end marker"           "$d/.curlrc" '# <<< jailbox managed proxy <<<'
    assert_mode     "enable: new curlrc gets mode 600"    "$d/.curlrc" "600"
    rm -rf "$d"
}

test_enable_creates_wgetrc() {
    local d; d=$(mktemp -d)
    run_script "$d" enable "http://proxy.test:8888"
    assert_exists   "enable: wgetrc created"              "$d/.wgetrc"
    assert_contains "enable: wgetrc use_proxy"            "$d/.wgetrc" "use_proxy = on"
    assert_contains "enable: wgetrc http_proxy"           "$d/.wgetrc" "http_proxy = http://proxy.test:8888"
    assert_contains "enable: wgetrc https_proxy"          "$d/.wgetrc" "https_proxy = http://proxy.test:8888"
    assert_mode     "enable: new wgetrc gets mode 600"    "$d/.wgetrc" "600"
    rm -rf "$d"
}

# ── enable: existing files ────────────────────────────────────────────────────

test_enable_preserves_user_content() {
    local d; d=$(mktemp -d)
    printf 'user-option = yes\n' > "$d/.curlrc"
    chmod 644 "$d/.curlrc"
    run_script "$d" enable "http://proxy.test:8888"
    assert_contains  "enable: user content preserved in curlrc" "$d/.curlrc" "user-option = yes"
    assert_contains  "enable: proxy block added to curlrc"      "$d/.curlrc" 'proxy = "http://proxy.test:8888"'
    assert_mode      "enable: existing curlrc mode not changed"  "$d/.curlrc" "644"
    rm -rf "$d"
}

test_enable_separates_user_content_from_block() {
    local d; d=$(mktemp -d)
    printf 'user-option = yes\n' > "$d/.curlrc"
    run_script "$d" enable "http://proxy.test:8888"
    # A blank line must separate user content from the managed block.
    if awk '/^$/{blank=1} /# >>> jailbox managed proxy >>>/{if(!blank) exit 1}' "$d/.curlrc"; then
        pass "enable: blank line separates user content from block"
    else
        fail "enable: blank line separates user content from block"
    fi
    rm -rf "$d"
}

test_enable_replaces_existing_block() {
    local d; d=$(mktemp -d)
    run_script "$d" enable "http://proxy1.test:8888"
    run_script "$d" enable "http://proxy2.test:8888"
    assert_count     "enable: only one begin marker in curlrc"  "$d/.curlrc" '# >>> jailbox managed proxy >>>' 1
    assert_contains  "enable: curlrc updated to new proxy URL"  "$d/.curlrc" 'proxy = "http://proxy2.test:8888"'
    assert_not_contains "enable: old proxy URL gone from curlrc" "$d/.curlrc" "proxy1.test"
    assert_count     "enable: only one begin marker in wgetrc"  "$d/.wgetrc" '# >>> jailbox managed proxy >>>' 1
    assert_contains  "enable: wgetrc updated to new proxy URL"  "$d/.wgetrc" "http_proxy = http://proxy2.test:8888"
    assert_not_contains "enable: old proxy URL gone from wgetrc" "$d/.wgetrc" "proxy1.test"
    rm -rf "$d"
}

test_enable_replaces_block_keeps_user_content() {
    local d; d=$(mktemp -d)
    printf 'user-option = yes\n' > "$d/.curlrc"
    run_script "$d" enable "http://proxy1.test:8888"
    run_script "$d" enable "http://proxy2.test:8888"
    assert_contains  "enable: user content still present after re-enable" "$d/.curlrc" "user-option = yes"
    assert_count     "enable: single begin marker after re-enable"        "$d/.curlrc" '# >>> jailbox managed proxy >>>' 1
    rm -rf "$d"
}

# ── disable: block-only files deleted ─────────────────────────────────────────

test_disable_removes_curlrc_when_only_block() {
    local d; d=$(mktemp -d)
    run_script "$d" enable  "http://proxy.test:8888"
    run_script "$d" disable
    assert_absent "disable: curlrc removed (contained only managed block)" "$d/.curlrc"
}

test_disable_removes_wgetrc_when_only_block() {
    local d; d=$(mktemp -d)
    run_script "$d" enable  "http://proxy.test:8888"
    run_script "$d" disable
    assert_absent "disable: wgetrc removed (contained only managed block)" "$d/.wgetrc"
}

# ── disable: user content preserved ──────────────────────────────────────────

test_disable_keeps_curlrc_with_user_content() {
    local d; d=$(mktemp -d)
    printf 'user-option = yes\n' > "$d/.curlrc"
    run_script "$d" enable  "http://proxy.test:8888"
    run_script "$d" disable
    assert_exists       "disable: curlrc kept (has user content)"   "$d/.curlrc"
    assert_contains     "disable: user content retained in curlrc"  "$d/.curlrc" "user-option = yes"
    assert_not_contains "disable: managed block removed from curlrc" "$d/.curlrc" "jailbox managed proxy"
}

test_disable_keeps_wgetrc_with_user_content() {
    local d; d=$(mktemp -d)
    printf 'http_proxy = http://existing.local:3128\n' > "$d/.wgetrc"
    run_script "$d" enable  "http://proxy.test:8888"
    run_script "$d" disable
    assert_exists       "disable: wgetrc kept (has user content)"   "$d/.wgetrc"
    assert_contains     "disable: user content retained in wgetrc"  "$d/.wgetrc" "http_proxy = http://existing.local:3128"
    assert_not_contains "disable: managed block removed from wgetrc" "$d/.wgetrc" "jailbox managed proxy"
}

# ── disable: no-op cases ──────────────────────────────────────────────────────

test_disable_noop_when_files_absent() {
    local d; d=$(mktemp -d)
    if run_script "$d" disable; then
        pass "disable: no-op when dotfiles don't exist"
    else
        fail "disable: no-op when dotfiles don't exist"
    fi
    assert_absent "disable: no curlrc created" "$d/.curlrc"
    assert_absent "disable: no wgetrc created" "$d/.wgetrc"
    rm -rf "$d"
}

test_disable_noop_when_no_managed_block() {
    local d; d=$(mktemp -d)
    printf 'user-option = yes\n' > "$d/.curlrc"
    run_script "$d" disable
    assert_exists   "disable: unmanaged curlrc untouched"         "$d/.curlrc"
    assert_contains "disable: unmanaged curlrc content unchanged" "$d/.curlrc" "user-option = yes"
    rm -rf "$d"
}

# ── bad invocation ────────────────────────────────────────────────────────────

test_unknown_subcommand_fails() {
    local d; d=$(mktemp -d)
    if run_script "$d" bogus 2>/dev/null; then
        fail "unknown subcommand: should exit non-zero"
    else
        pass "unknown subcommand: exits non-zero"
    fi
    rm -rf "$d"
}

test_enable_without_url_fails() {
    local d; d=$(mktemp -d)
    if run_script "$d" enable 2>/dev/null; then
        fail "enable without URL: should exit non-zero"
    else
        pass "enable without URL: exits non-zero"
    fi
    rm -rf "$d"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    [[ -f "$MANAGE_PROXY" ]] || { echo "Script not found: $MANAGE_PROXY" >&2; exit 1; }

    echo "downloader-proxy tests"
    echo ""

    test_enable_creates_curlrc
    test_enable_creates_wgetrc
    test_enable_preserves_user_content
    test_enable_separates_user_content_from_block
    test_enable_replaces_existing_block
    test_enable_replaces_block_keeps_user_content
    test_disable_removes_curlrc_when_only_block
    test_disable_removes_wgetrc_when_only_block
    test_disable_keeps_curlrc_with_user_content
    test_disable_keeps_wgetrc_with_user_content
    test_disable_noop_when_files_absent
    test_disable_noop_when_no_managed_block
    test_unknown_subcommand_fails
    test_enable_without_url_fails

    echo ""
    if [[ "$FAILED" -eq 0 ]]; then
        echo "downloader-proxy tests: $PASSED passed"
    else
        echo "downloader-proxy tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
