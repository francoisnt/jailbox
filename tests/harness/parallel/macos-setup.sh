#!/bin/bash
# Machine setup must target its named rootless connection and fail closed.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/ci/setup-macos.sh
source "$ROOT/tests/ci/setup-macos.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GITHUB_ENV="$tmp/github-env"
PODMAN_MACHINE_NAME=jailbox-ci
scenario=absent
podman() {
    printf '%s\n' "$*" >> "$tmp/calls"
    case "$1 ${2:-}" in
        'machine list')
            [[ "$scenario" != list-failure ]] || return 42
            [[ "$scenario" = absent || "$scenario" = init-failure ]] || printf 'jailbox-ci\n'
            ;;
        'machine init') [[ "$scenario" != init-failure ]] || return 42 ;;
        'machine inspect')
            [[ "$scenario" != inspect-failure ]] || return 42
            if [[ "$scenario" = running ]]; then printf 'running\n'; else printf 'stopped\n'; fi
            ;;
        'machine start') [[ "$scenario" != start-failure ]] || return 42 ;;
        'info ') [[ "$CONTAINER_CONNECTION" = jailbox-ci ]] ;;
        *) return 1 ;;
    esac
}
for scenario in absent running stopped list-failure init-failure inspect-failure start-failure; do
    : > "$tmp/calls"
    : > "$GITHUB_ENV"
    unset CONTAINER_CONNECTION
    status=0
    start_podman_machine || status=$?
    case "$scenario" in
        absent)
            [[ "$status" = 0 ]]
            grep -Fq 'machine init --rootful=false' "$tmp/calls"
            grep -Fxq "machine start --update-connection=false jailbox-ci" "$tmp/calls"
            ;;
        running)
            [[ "$status" = 0 ]]
            if grep -Eq '^machine (init|start)' "$tmp/calls"; then exit 1; fi
            ;;
        stopped)
            [[ "$status" = 0 ]]
            if grep -q '^machine init' "$tmp/calls"; then exit 1; fi
            ;;
        *)
            [[ "$status" != 0 ]]
            if grep -q '^info' "$tmp/calls"; then exit 1; fi
            case "$scenario" in
                list-failure|init-failure|inspect-failure)
                    if grep -q '^machine start' "$tmp/calls"; then exit 1; fi ;;
            esac
            continue
            ;;
    esac
    grep -Fxq CONTAINER_CONNECTION=jailbox-ci "$GITHUB_ENV"
    grep -Fxq info "$tmp/calls"
done
printf 'PASS: macOS machine selection, reuse, and failure sequencing\n'
