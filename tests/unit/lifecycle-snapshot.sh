#!/bin/bash
# Snapshot batching preserves bytes and rejects failed data producers.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
PREFIX=fixture
NETWORK=fixture-net
HOME_VOLUME=fixture-home
PROJECT="$tmp/project"
XDG_STATE_HOME="$tmp/state"
mkdir -p "$PROJECT" "$XDG_STATE_HOME" "$tmp/home" "$tmp/bin"
printf config > "$PROJECT/jailbox.conf"
printf state > "$XDG_STATE_HOME/key with spaces"
printf home > "$tmp/home/marker"
chmod 700 "$XDG_STATE_HOME" "$tmp/home"
chmod 600 "$XDG_STATE_HOME/key with spaces" "$tmp/home/marker"
ln -s "$tmp/home" "$XDG_STATE_HOME/link"
mkfifo -m 600 "$XDG_STATE_HOME/fifo"
FAIL_AT=''
podman() {
    printf '%s\n' "$*" >> "$tmp/calls"
    case "$1:$2" in
        container:ls)
            [[ "$*" = "container ls --all --format {{.Names}}" ]] || return 99 ;;
        network:ls|volume:ls)
            [[ "$*" = "$1 ls --format {{.Name}}" ]] || return 99 ;;
    esac
    if [[ "$1" = unshare ]]; then
        [[ "$FAIL_AT" != unshare ]] || return 42
        shift
        "$@"
        return
    fi
    case "$2" in
        ls)
            # Unrelated and prefix/suffix matches must never enter snapshots.
            printf '%s\n' unrelated fixture-suffix xfixture
            cat "$tmp/$1"
            [[ "$FAIL_AT" != "$1:ls" ]] || return 42 ;;
        exists) grep -Fxq -- "$3" "$tmp/$1" ;;
        inspect)
            [[ "$FAIL_AT" != "$1:inspect" ]] || return 42
            if [[ "$*" = "volume inspect $HOME_VOLUME --format {{.Mountpoint}}" ]]; then
                [[ "$FAIL_AT" != mountpoint ]] || return 42
                printf '%s\n' "$tmp/home"
            else
                printf 'inspection:%s:%s\n' "$1" "$3"
            fi ;;
        *) return 99 ;;
    esac
}
# Frozen reference for the original snapshot ordering and filesystem format.
reference_filesystem() {
    [[ -e "$1" ]] || return 0
    (
        cd "$1" || exit 1
        find . -printf '%P|%y|%U|%G|%m|%i|%s|%T@|%l\n' | LC_ALL=C sort
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    )
}
reference_snapshot() {
    local kind name
    for kind in container network volume; do
        for name in "$PREFIX" "$PREFIX-proxy" "$NETWORK" "$NETWORK-internal" "$NETWORK-external" "$HOME_VOLUME"; do
            if podman "$kind" exists "$name"; then
                printf '%s:%s\n' "$kind" "$name"
                printf 'inspection:%s:%s\n' "$kind" "$name"
            fi
        done
    done
    reference_filesystem "$XDG_STATE_HOME"
    if podman volume exists "$HOME_VOLUME"; then reference_filesystem "$tmp/home"; fi
    sha256sum "$PROJECT/jailbox.conf"
}
compare() {
    reference_snapshot > "$tmp/expected"
    : > "$tmp/calls"
    snapshot > "$tmp/actual"
    cmp "$tmp/expected" "$tmp/actual" || fail 'snapshot bytes changed'
    [[ $(grep -c ' ls ' "$tmp/calls") = 3 ]] || fail 'discovery was not batched'
    [[ $(grep -c '^unshare ' "$tmp/calls") = 1 ]] || fail 'filesystem walks were not batched'
    if grep -q ' exists ' "$tmp/calls"; then fail 'per-name probes remain'; fi
}
for kind in container network volume; do : > "$tmp/$kind"; done
compare
# Every kind/name combination, including names under unexpected kinds.
for kind in container network volume; do
    for name in "$PREFIX" "$PREFIX-proxy" "$NETWORK" "$NETWORK-internal" "$NETWORK-external" "$HOME_VOLUME"; do
        printf '%s\n' "$name" > "$tmp/$kind"
        compare
    done
    : > "$tmp/$kind"
done
for kind in container network volume; do
    printf '%s\n' "$PREFIX" "$PREFIX-proxy" "$NETWORK" "$NETWORK-internal" "$NETWORK-external" "$HOME_VOLUME" > "$tmp/$kind"
done
compare
# Conditional invocation must propagate producer errors, even after output.
for FAIL_AT in container:ls network:ls volume:ls container:inspect network:inspect volume:inspect mountpoint unshare; do
    if snapshot > "$tmp/failed"; then fail "accepted failed $FAIL_AT"; fi
done
FAIL_AT=''
# A missing first root must not skip the second root.
filesystem_snapshot "$tmp/missing" "$tmp/home" > "$tmp/actual"
reference_filesystem "$tmp/home" > "$tmp/expected"
cmp "$tmp/expected" "$tmp/actual"
# Failure of either walk stops the combined namespace command. The wrappers
# target actual child processes, where conditional-call errexit differs.
SNAPSHOT_REAL_FIND=$(command -v find)
export SNAPSHOT_REAL_FIND
cat > "$tmp/bin/find" <<'STUB'
#!/bin/bash
if [[ "$PWD" = "$FAIL_ROOT" ]]; then exit 42; fi
exec "$SNAPSHOT_REAL_FIND" "$@"
STUB
chmod 755 "$tmp/bin/find"
for FAIL_ROOT in "$XDG_STATE_HOME" "$tmp/home"; do
    export FAIL_ROOT
    if PATH="$tmp/bin:$PATH" filesystem_snapshot "$XDG_STATE_HOME" "$tmp/home" > "$tmp/failed"; then
        fail 'accepted failed filesystem walk'
    fi
done
printf 'PASS: snapshot bytes preserved across all resource kinds/names; discovery and walk failures propagate\n'
