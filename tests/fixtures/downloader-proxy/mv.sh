#!/bin/bash
set -euo pipefail
destination=${!#}
if [[ "$PROXY_TEST_FAULT" = second-publication && "$destination" = */.wgetrc ]]; then exit 1; fi
"$HOME/real-mv" "$@"
if [[ "$PROXY_TEST_FAULT" = after-first-publication && "$destination" = */.curlrc ]]; then
    # The target must be a direct child of the explicitly identified manager,
    # never the manager itself or another ancestor of the test process.
    parent_parent=$(ps -o ppid= -p "$PPID")
    parent_parent=${parent_parent//[[:space:]]/}
    [[ "$PPID" != "$PROXY_TEST_MANAGER_PID" && "$parent_parent" = "$PROXY_TEST_MANAGER_PID" ]] || {
        echo 'Unexpected proxy interruption target' >&2
        exit 97
    }
    printf 'verified sync child\n' > "$HOME/kill-confirmed"
    kill -KILL "$PPID"
fi
