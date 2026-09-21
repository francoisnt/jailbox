#!/bin/bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/frontend/settings.sh"

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
    declare -gA EDITOR_CONNECTION=(
        [ssh_config]="$SSH_CONFIG" [proxy_url]="http://10.240.1.2:8888"
    )
}

test_egress_editor_settings_include_proxy() {
    local settings

    with_settings_file
    settings="$JAILBOX_EDITOR_USER_SETTINGS"

    write_editor_settings "$JAILBOX_EDITOR_USER_SETTINGS"

    assert_contains "egress settings include SSH config" "$settings" "\"remote.SSH.configFile\": \"$SSH_CONFIG\""
    assert_contains "egress settings include editor HTTP proxy" "$settings" "\"http.proxy\": \"${EDITOR_CONNECTION[proxy_url]}\""
    assert_not_contains "egress settings omit terminal proxy env" "$settings" "\"terminal.integrated.env.linux\""
    rm -rf "$SETTINGS_DIR"
}

test_non_egress_editor_settings_skip_proxy() {
    local settings

    with_settings_file
    settings="$JAILBOX_EDITOR_USER_SETTINGS"
    EDITOR_CONNECTION[proxy_url]=""

    write_editor_settings "$JAILBOX_EDITOR_USER_SETTINGS"

    assert_contains "non-egress settings include SSH config" "$settings" "\"remote.SSH.configFile\": \"$SSH_CONFIG\""
    assert_not_contains "non-egress settings omit editor HTTP proxy" "$settings" "\"http.proxy\""
    assert_not_contains "non-egress settings omit terminal proxy env" "$settings" "\"terminal.integrated.env.linux\""
    rm -rf "$SETTINGS_DIR"
}

main() {
    echo "editor settings tests"
    echo ""

    test_egress_editor_settings_include_proxy
    test_non_egress_editor_settings_skip_proxy

    echo ""
    if [ "$FAILED" -eq 0 ]; then
        echo "editor settings tests: $PASSED passed"
    else
        echo "editor settings tests: $PASSED passed, $FAILED failed"
        exit 1
    fi
}

main "$@"
