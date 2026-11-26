#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/ci/setup-common.sh
source "$ROOT/tests/ci/setup-common.sh"

attempts=0
failures=0
delays=()
code() {
    [[ $# = 3 && $1 = --install-extension && $2 = ms-vscode-remote.remote-ssh@0.1.2 && $3 = --force ]] || return 99
    attempts=$((attempts + 1))
    if ((attempts <= failures)); then return 42; fi
    return 0
}
sleep() { delays+=("$1"); }

# A successful install is never repeated.
install_extension_with_retry code --install-extension ms-vscode-remote.remote-ssh@0.1.2 --force
[[ $attempts = 1 && -z ${delays[*]-} ]]

# Two transient errors followed by success retry the same pinned extension.
attempts=0
failures=2
install_extension_with_retry code --install-extension ms-vscode-remote.remote-ssh@0.1.2 --force
[[ $attempts = 3 && ${delays[*]} = '5 10' ]]

# A persistent error is returned after the bounded attempts, without a
# final unnecessary delay or permission to run the editor tests.
attempts=0
failures=3
delays=()
status=0
install_extension_with_retry code --install-extension ms-vscode-remote.remote-ssh@0.1.2 --force || status=$?
[[ $status = 42 && $attempts = 3 && ${delays[*]} = '5 10' ]]
