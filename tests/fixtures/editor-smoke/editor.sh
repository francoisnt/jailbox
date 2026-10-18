#!/bin/bash
# Trust is test-only setup; product launch does not disable workspace trust.
set -euo pipefail
if [[ " $* " = *' --list-extensions '* ]]; then
    exec "$JAILBOX_TEST_EDITOR_REAL" "$@"
fi
if [[ ${JAILBOX_TEST_SEED_SETTINGS:-1} == 1 ]]; then
printf '{"security.workspace.trust.enabled":false,"task.allowAutomaticTasks":"on"}\n' |
    "$JAILBOX_TEST_CLI" exec /usr/local/bin/jailbox-write-editor-settings || exit $?
fi
if [[ -n ${JAILBOX_TEST_EDITOR_LOG_DIR:-} ]]; then
    mkdir -p -- "$JAILBOX_TEST_EDITOR_LOG_DIR" || exit $?
    launch_logs=$(mktemp -d "$JAILBOX_TEST_EDITOR_LOG_DIR/launch.XXXXXX") || exit $?
    printf '  Editor launch logs: %s\n' "${launch_logs#"${JAILBOX_TEST_LOG_ROOT:-}/"}"
    # A separate directory retains every invocation, even when a later launch
    # fails before Electron creates its own logs. Do not use --verbose: it waits
    # for the window to close and would block the attachment assertions.
    exec >> "$launch_logs/launcher.log" 2>&1
    printf '[%s] Starting editor\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exec "$JAILBOX_TEST_EDITOR_REAL" --log trace --logsPath "$launch_logs" --disable-workspace-trust "$@"
fi
exec "$JAILBOX_TEST_EDITOR_REAL" --disable-workspace-trust "$@"
