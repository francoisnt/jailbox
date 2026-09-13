#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Exercise the allocator without launching the end-to-end script or Podman.
# shellcheck disable=SC1090
source <(sed -n '/^headless_fixture() {/,/^}/p' "$ROOT/tests/e2e/headless.sh")
declare -F headless_fixture >/dev/null || fail 'could not extract headless_fixture'
stub_dir="$fixture/stubs"
mkdir -p "$stub_dir/ports/62000"
printf '0\n' > "$fixture/count"
mktemp() {
    local count
    count=$(cat "$fixture/count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$fixture/count"
    mkdir "$fixture/candidate-$count"
    printf '%s\n' "$fixture/candidate-$count"
}
jailbox_project_hash_for_path() { printf '%s\n' "${1##*-}"; }
jailbox_project_hash_port_offset() {
    case "$1" in
        1) printf '0\n' ;; # Rejected by the availability check.
        2) printf '12848\n' ;; # 62000 is already claimed by a sibling.
        *) printf '12849\n' ;; # 62001 is usable once.
    esac
}
test_fixture_port_available() { [[ "$1" != 49152 ]]; }
die() { printf '%s\n' "$*" >&2; return 1; }

project=$(headless_fixture debian)
[[ "$project" = "$fixture/candidate-3" && -d "$project" ]] || fail 'wrong fixture selected'
[[ ! -e "$fixture/candidate-1" && ! -e "$fixture/candidate-2" ]] || fail 'rejected directories leaked'
[[ -d "$stub_dir/ports/62000" && -d "$stub_dir/ports/62001" ]] || fail 'port claims lost'
# The first stage keeps its claim even before its container binds the port.
if headless_fixture alpine > "$fixture/output" 2> "$fixture/error"; then
    fail 'a second stage reused a claimed port'
fi
[[ $(cat "$fixture/count") = 103 ]] || fail 'allocation retry bound changed'
[[ ! -s "$fixture/output" ]] || fail 'failed allocation published a project'
grep -Fq 'could not allocate a free SSH port' "$fixture/error"
[[ $(find "$fixture" -maxdepth 1 -name 'candidate-*' | wc -l) = 1 ]] || fail 'failed allocation leaked directories'
printf 'PASS: headless fixtures reject unavailable and claimed ports with bounded cleanup\n'
