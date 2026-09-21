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
exec "$JAILBOX_TEST_EDITOR_REAL" --disable-workspace-trust "$@"
