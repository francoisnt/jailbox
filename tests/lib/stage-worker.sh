#!/bin/bash
# Internal worker entrypoint: load a runner without starting its coordinator.
set -euo pipefail
runner=$1
context=$2
callback=$3
shift 3
# shellcheck disable=SC1090 # The coordinator supplies its own runner path.
source "$runner"
while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    [[ " $STAGE_WORKER_VARIABLES " = *" $name "* ]] || exit 1
    printf -v "$name" '%s' "$value"
done < "$context"
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$callback" "$@"
