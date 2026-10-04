#!/bin/bash
# Local-repository pre-push fixture: reject policy or advance master mid-push.
set -euo pipefail
printf 'push\n' >> "${PUSH_LOG:?}"
if [[ ${PUSH_MODE:?} == reject ]]; then
    echo 'Fixture policy rejected this push.' >&2
    exit 1
fi
if [[ ! -e ${PUSH_MOVED:?} ]]; then
    touch "$PUSH_MOVED"
    # Hook-local Git variables must not redirect commands for the other clone.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
    git -C "${PUSH_OTHER:?}" commit --allow-empty -m 'Concurrent fixture commit' || exit 1
    git -C "$PUSH_OTHER" push origin master || exit 1
fi
