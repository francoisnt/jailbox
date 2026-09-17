#!/bin/bash
# Local validation has no engine, transport, hash, editor, or state dependency.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASH_BIN=$(command -v bash)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/project" "$tmp/bin"
for tool in bash dirname basename realpath; do
    ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
export XDG_STATE_HOME="$tmp/state"
cd "$tmp/project"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cli() { PATH="$tmp/bin" "$BASH_BIN" "$ROOT/jailbox" "$@"; }
check() {
    local expectation="$1" result=0
    shift
    cli "$@" > "$tmp/out" 2> "$tmp/err" || result=$?
    if [[ "$expectation" = valid ]]; then
        [[ "$result" = 0 ]] || { cat "$tmp/err"; fail 'valid configuration rejected'; }
        grep -q 'Configuration and local launch inputs' "$tmp/out" || fail 'success scope missing'
    else
        [[ "$result" != 0 && ! -s "$tmp/out" && -s "$tmp/err" ]] || fail 'invalid configuration succeeded or printed success'
    fi
    [[ ! -e "$XDG_STATE_HOME" ]] || fail 'validation created runtime state'
}
# shellcheck disable=SC2016 # Deliberately malicious file data, never executed.
printf 'invalid configuration $(touch injected)\n' > jailbox.conf
check invalid validate
printf 'FROM debian\n' > Containerfile
chmod 644 Containerfile jailbox.conf
check valid validate
check invalid --config jailbox.conf validate
check invalid validate extra
for assignment in JAILBOX_CONFIG_UNKNOWN=x JAILBOX_CONFIG_EPHEMERAL_HOME=bad JAILBOX_CONFIG_EGRESS_ALLOW_1=example.com JAILBOX_CONFIG_READONLY_PATHS_0=../outside JAILBOX_CONFIG_DEV_BUILD_CONTEXT=missing JAILBOX_CONFIG_DEV_CONTAINERFILE=missing; do
    export "${assignment?}"
    check invalid validate
    unset "${assignment%%=*}"
done
mkdir 'context space'
JAILBOX_CONFIG_DEV_BUILD_CONTEXT='context space' check valid validate
ln -s 'context space' link
JAILBOX_CONFIG_DEV_BUILD_CONTEXT="link" check invalid validate
chmod 000 Containerfile
check invalid validate
chmod 644 Containerfile
rm Containerfile
mkdir Containerfile
JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile check invalid validate
# Explicit images bypass even invalid unused file/context objects.
JAILBOX_CONFIG_DEV_IMAGE=example JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile JAILBOX_CONFIG_DEV_BUILD_CONTEXT="link" check valid validate
rmdir Containerfile
printf 'FROM debian\n' > Dockerfile
check valid validate
# A required producer failure must not become a successful local check.
export VALIDATE_REALPATH VALIDATE_PROJECT
VALIDATE_REALPATH=$(command -v realpath)
VALIDATE_PROJECT=$PWD
rm "$tmp/bin/realpath"
# Fail only the containment check, after successful file canonicalization.
# Plausible output must not hide the producer's nonzero status.
cat > "$tmp/bin/realpath" <<'REALPATH'
#!/bin/bash
"$VALIDATE_REALPATH" "$@" || exit $?
[[ "$*" != "-- $VALIDATE_PROJECT" ]] || exit 42
REALPATH
chmod 755 "$tmp/bin/realpath"
check invalid validate
grep -q 'cannot establish project containment' "$tmp/err" || fail 'containment failure was hidden'
# A genuinely outside Containerfile remains valid and needs no project mount.
cp "$VALIDATE_REALPATH" "$tmp/bin/realpath"
printf 'FROM debian\n' > "$tmp/outside.Containerfile"
chmod 644 "$tmp/outside.Containerfile"
JAILBOX_CONFIG_DEV_CONTAINERFILE="$tmp/outside.Containerfile" check valid validate
rm "$tmp/bin/realpath"
printf '#!/bin/bash\nprintf plausible\nexit 42\n' > "$tmp/bin/realpath"
chmod 755 "$tmp/bin/realpath"
check invalid validate
[[ ! -e injected ]] || fail 'configuration was executed'
# No command alias remains.
check invalid doctor
printf 'PASS: validate checks local launch inputs without engine, SSH, hash, editor, or state\n'
