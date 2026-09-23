#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
if (
    PROJECT_HASH=abcdef123456
    CONFIG_DIGEST_LABEL_ARGS=()
    podman() { printf 'engine permission denied\n' >&2; return 125; }
    ensure_internal_network review-internal
) > "$fixture/out" 2> "$fixture/err"; then fail 'network failure accepted'; fi
[[ ! -s "$fixture/out" ]]
grep -Fq 'engine permission denied' "$fixture/err"
grep -Fq 'tried 20 subnet candidates' "$fixture/err"
if (
    PROJECT_DEV_IMAGE=review-image DEV_TARGET_STAGE=dev PKG_MANAGER=apk MY_UID=1000
    jailbox_install_cache_bust() { printf '123\n'; }
    podman() { case "$1 $2" in 'image exists') return 0 ;; 'image inspect') printf 'image-id\n' ;; *) return 42 ;; esac; }
    build_jailbox_image
) > "$fixture/out" 2> "$fixture/err"; then fail 'image failure accepted'; fi
grep -Fq 'Error: jailbox image build failed.' "$fixture/err"
grep -Fq 'Stage:           dev' "$fixture/err"
grep -Fq 'Fix:' "$fixture/err"
if grep -Eq 'Error:|Common causes:|Fix:' "$fixture/out"; then fail 'image diagnostics on stdout'; fi
if (
    CONTAINER_NAME=review SSH_CONFIG=/unused
    ssh() { return 1; }
    sleep() { :; }
    podman() { printf 'daemon diagnostic\n'; }
    wait_for_ssh
) > "$fixture/out" 2> "$fixture/err"; then fail 'SSH failure accepted'; fi
grep -Fq 'podman logs review' "$fixture/err"
grep -Fq 'daemon diagnostic' "$fixture/err"
if grep -q 'podman logs' "$fixture/out"; then fail 'SSH hint on stdout'; fi
printf 'PASS: network, image-build, and SSH failure context reaches stderr\n'
