#!/bin/bash
# Both preparation modes retain canonical inputs; runtime still checks the
# restrictive installation scenario before publishing the canonical wrapper.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
for cache_scenario in prepare contract failure; do
    mkdir "$fixture/$cache_scenario"
    result=0
    (
        # shellcheck source=tests/integration/wrapper-images.sh
        source "$ROOT/tests/integration/wrapper-images.sh"
        PREPARE_ONLY=false
        [[ "$cache_scenario" != prepare ]] || PREPARE_ONLY=true
        while read -r _ _ function; do
            case "$function" in
                assert_*) eval "$function() { :; }" ;;
            esac
        done < <(declare -F)
        # shellcheck disable=SC2329 # Called by run_case.
        setup_ssh_keys() { :; }
        # shellcheck disable=SC2329
        prepare_server_keys() { :; }
        # shellcheck disable=SC2329
        wait_for_ssh() { :; }
        # shellcheck disable=SC2329
        podman() {
            if [[ "$1" = run && "$*" = *'-u jailbox'* ]]; then printf '1000\n'; fi
            if [[ "$1 $2" = 'image inspect' ]]; then printf 'immutable-base\n'; fi
            if [[ "$1" = build && "$*" = *Containerfile.wrapper* ]]; then
                local context=${!#}
                if [[ "$context" = "$ROOT/src/container" ]]; then
                    printf 'canonical\n' >> "$fixture/$cache_scenario/builds"
                    [[ "$cache_scenario" != failure ]] || return 7
                else
                    printf 'restrictive\n' >> "$fixture/$cache_scenario/builds"
                    python3 -c 'import os,sys; assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o700' "$context/runtime" || return 1
                    python3 -c 'import os,sys; assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600' "$context/runtime/bin/jailbox-start" || return 1
                fi
            fi
            return 0
        }
        run_case debian "$fixture/$cache_scenario"
    ) > "$fixture/$cache_scenario/output" 2>&1 || result=$?
    if [[ "$cache_scenario" = prepare ]]; then
        [[ $(cat "$fixture/$cache_scenario/builds") = canonical && "$result" = 0 ]]
    else
        [[ $(cat "$fixture/$cache_scenario/builds") = $'restrictive\ncanonical' ]]
        if [[ "$cache_scenario" = failure ]]; then [[ "$result" != 0 ]]; else [[ "$result" = 0 ]]; fi
    fi
done
printf 'PASS: canonical wrapper preparation preserves restrictive runtime coverage and build failures\n'
