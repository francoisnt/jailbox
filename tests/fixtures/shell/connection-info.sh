#!/bin/bash
set -euo pipefail
[[ $# = 1 && "$1" = connection-info ]]
cat "$SHELL_CONNECTION_REPLY"
exit "$SHELL_CONNECTION_STATUS"
