#!/bin/bash
set -euo pipefail
export PROXY_TEST_MANAGER_PID=$BASHPID
"$HOME/bin/mv" "$HOME/replacement" "$HOME/.curlrc"
