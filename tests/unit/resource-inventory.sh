#!/bin/bash
# Group discovery without retaining inventory across calls or hiding failures.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=host/container-runtime.sh
source "$ROOT/host/container-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { fail "$@"; }
LIST_FAILURE=false
podman() {
    printf '%s\n' "$*" >> "$tmp/calls"
    case "$2" in
        ls)
            if [[ "$1" = container && "$*" != 'container ls --all --format {{.Names}}' ]]; then return 99; fi
            cat "$tmp/$1"
            [[ "$LIST_FAILURE" = false ]] || return 125 ;;
        exists) grep -Fxq -- "$3" "$tmp/$1" ;;
        *) return 99 ;;
    esac
}
for kind in container network volume image; do : > "$tmp/$kind"; done
: > "$tmp/calls"
resolve_present_resources present
[[ -z ${present[*]-} && ! -s "$tmp/calls" ]]
# Small groups keep cheaper individual probes, even for absent resources.
resolve_present_resources present network:a container:c volume:v image:i
[[ $(wc -l < "$tmp/calls") = 4 ]]
if grep -q ' ls ' "$tmp/calls"; then fail 'small groups used listings'; fi
: > "$tmp/calls"
printf 'a\nab\nxa\n' > "$tmp/network"
printf 'c\n' > "$tmp/container"
printf 'v\n' > "$tmp/volume"
resolve_present_resources present network:a container:c network:b volume:v volume:w
[[ ${present[*]} = 'network:a container:c volume:v' ]] || fail 'membership or input order changed'
[[ $(grep -c ' ls ' "$tmp/calls") = 2 && $(grep -c ' exists ' "$tmp/calls") = 1 ]]
# Four container probes remain cheaper; five use one listing, including stopped.
: > "$tmp/calls"
resolve_present_resources present container:a container:b container:c container:d
[[ $(wc -l < "$tmp/calls") = 4 ]]
: > "$tmp/calls"
resolve_present_resources present container:a container:b container:c container:d container:e
[[ ${present[*]} = container:c && $(wc -l < "$tmp/calls") = 1 ]]
# Empty successful listings establish absence. Each call obtains fresh data.
: > "$tmp/network"
: > "$tmp/calls"
resolve_present_resources present network:a network:b
[[ -z ${present[*]-} ]]
printf 'b\n' > "$tmp/network"
resolve_present_resources present network:a network:b
[[ ${present[*]} = network:b && $(wc -l < "$tmp/calls") = 2 ]]
LIST_FAILURE=true
if (resolve_present_resources present network:a network:b) > "$tmp/out" 2>&1; then
    fail 'failed listing with plausible output was accepted'
fi
: > "$tmp/network"
if (resolve_present_resources present network:a network:b) > "$tmp/out" 2>&1; then
    fail 'failed empty listing was accepted as absence'
fi
if (resolve_present_resources present 'unknown:a') > "$tmp/out" 2>&1; then
    fail 'invalid resource type accepted'
fi
printf 'PASS: inventory grouping preserves names, order, fresh reads and producer failures\n'
