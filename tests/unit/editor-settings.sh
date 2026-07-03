#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/editor.sh"

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_contains() {
    local name="$1" file="$2" expected="$3"

    if grep -Fq "$expected" "$file"; then
        pass "$name"
    else
        fail "$name (missing '$expected')"
    fi
}

assert_not_contains() {
    local name="$1" file="$2" unexpected="$3"

    if grep -Fq "$unexpected" "$file"; then
        fail "$name (found '$unexpected')"
    else
        pass "$name"
    fi
}

with_settings_file() {
    SETTINGS_DIR=$(mktemp -d)
    JAILBOX_EDITOR_USER_SETTINGS="$SETTINGS_DIR/User/settings.json"
    SSH_CONFIG="$SETTINGS_DIR/ssh_config"
    PROXY_URL="http://proxy.test:8888"
    PROXY_NO_PROXY="localhost,127.0.0.1"
}

test_egress_editor_settings_include_proxy() {
    local settings

    with_settings_file
    settings="$JAILBOX_EDITOR_USER_SETTINGS"
    EGRESS_ALLOW=(api.example.test)
    JAILBOX_EDITOR_SMOKE_TEST_SETTINGS=""

    write_jailbox_editor_user_settings

    assert_contains "egress settings include SSH config" "$settings" "\"remote.SSH.configFile\": \"$SSH_CONFIG\""
    assert_contains "egress settings include editor HTTP proxy" "$settings" "\"http.proxy\": \"$PROXY_URL\""
    assert_contains "egress settings include terminal proxy env" "$settings" "\"terminal.integrated.env.linux\""
    rm -rf "$SETTINGS_DIR"
}

test_non_egress_editor_settings_skip_proxy() {
    local settings

    with_settings_file
    settings="$JAILBOX_EDITOR_USER_SETTINGS"
    EGRESS_ALLOW=()
    JAILBOX_EDITOR_SMOKE_TEST_SETTINGS=""

    write_jailbox_editor_user_settings

    assert_contains "non-egress settings include SSH config" "$settings" "\"remote.SSH.configFile\": \"$SSH_CONFIG\""
    assert_not_contains "non-egress settings omit editor HTTP proxy" "$settings" "\"http.proxy\""
    assert_not_contains "non-egress settings omit terminal proxy env" "$settings" "\"terminal.integrated.env.linux\""
    rm -rf "$SETTINGS_DIR"
}

test_smoke_machine_settings_include_proxy_in_egress() {
    local output

    EGRESS_ALLOW=(api.example.test)
    PROXY_URL="http://proxy.test:8888"

    output=$(editor_smoke_settings_json_object)

    if grep -Fq "\"http.proxy\": \"$PROXY_URL\"" <<< "$output"; then
        pass "smoke machine settings include editor HTTP proxy in egress"
    else
        fail "smoke machine settings include editor HTTP proxy in egress"
    fi
}

main() {
    echo "editor settings tests"
    echo ""

    test_egress_editor_settings_include_proxy
    test_non_egress_editor_settings_skip_proxy
    test_smoke_machine_settings_include_proxy_in_egress

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "editor settings tests: $PASSED passed"
    else
        echo "editor settings tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
