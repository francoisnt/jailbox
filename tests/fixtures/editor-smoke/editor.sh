#!/bin/bash
# Trust is test-only setup; product launch does not disable workspace trust.
set -euo pipefail
if [[ " $* " = *' --list-extensions '* ]]; then
    exec "$JAILBOX_TEST_EDITOR_REAL" "$@"
fi
printf '{"security.workspace.trust.enabled":false,"task.allowAutomaticTasks":"on"}\n' |
    "$JAILBOX_TEST_CLI" exec /usr/local/bin/jailbox-write-editor-settings || exit $?
exec "$JAILBOX_TEST_EDITOR_REAL" --disable-workspace-trust "$@"
