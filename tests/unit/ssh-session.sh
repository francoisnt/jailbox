#!/bin/bash
# Test the production POSIX startup conversion without a container or sshd.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/^ssh_session_environment() ($/,/^)/p' "$ROOT/src/container/runtime/bin/jailbox-start" > "$tmp/session"
[[ -s "$tmp/session" ]]
printf '\nssh_session_environment\n' >> "$tmp/session"
for shell in sh bash; do
    # The resulting argument is data, even in a login/conditional caller.
    JAILBOX_SSH_PROXY_URL=http://10.240.32.2:8888 "$shell" "$tmp/session" > "$tmp/actual"
    printf '%s\n' 'SetEnv HTTP_PROXY=http://10.240.32.2:8888 HTTPS_PROXY=http://10.240.32.2:8888 http_proxy=http://10.240.32.2:8888 https_proxy=http://10.240.32.2:8888 NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1' > "$tmp/expected"
    cmp "$tmp/expected" "$tmp/actual"
    JAILBOX_SSH_PROXY_URL='' "$shell" "$tmp/session" > "$tmp/actual"
    printf '%s\n' 'SetEnv HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY= no_proxy=' > "$tmp/expected"
    cmp "$tmp/expected" "$tmp/actual"
    if (unset JAILBOX_SSH_PROXY_URL; "$shell" "$tmp/session") > "$tmp/actual" 2> "$tmp/error"; then
        echo 'FAIL: missing proxy input accepted' >&2; exit 1
    fi
    [[ ! -s "$tmp/actual" ]]
    # shellcheck disable=SC2016 # Malicious input must stay literal data.
    for invalid in 'http://10.0.0.1:8888 OTHER=value' $'http://10.0.0.1:8888\nAllowUsers *' \
        'http://$(touch marker):8888' 'http://10.*.0.1:8888' 'http://10.0.0.1.:8888' \
        'http://10..0.1:8888' 'http://256.0.0.1:8888' 'http://10.0.1:8888' \
        'http://10.0.0.1:80' 'https://10.0.0.1:8888'; do
        if JAILBOX_SSH_PROXY_URL="$invalid" "$shell" "$tmp/session" > "$tmp/actual" 2> "$tmp/error"; then
            echo 'FAIL: invalid proxy input accepted' >&2; exit 1
        fi
        [[ ! -s "$tmp/actual" ]]
    done
done

# Exercise the real startup tail with an executable daemon double. A failed
# producer or syntax check must prevent the daemon exec, and image proxy values
# must not leak into the daemon's environment.
sed -n '/^ssh_session_environment() ($/,/^)/p; /^session_env=/,$p' "$ROOT/src/container/runtime/bin/jailbox-start" > "$tmp/start"
cp "$ROOT/tests/fixtures/ssh-session/sshd.sh" "$tmp/sshd"
chmod 755 "$tmp/sshd"
export SSHD="$tmp/sshd" SESSION_TRACE="$tmp/trace"
export HTTP_PROXY=stale HTTPS_PROXY=stale http_proxy=stale https_proxy=stale NO_PROXY=stale no_proxy=stale
JAILBOX_SSH_PROXY_URL='' sh "$tmp/start"
[[ $(grep -c -- '^-t$\|^-D$' "$SESSION_TRACE") == 2 ]]
grep -qx 'SetEnv HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY= no_proxy=' "$SESSION_TRACE"
: > "$SESSION_TRACE"
if JAILBOX_SSH_PROXY_URL='' SESSION_CHECK_STATUS=42 sh "$tmp/start"; then
    echo 'FAIL: failed daemon check accepted' >&2; exit 1
fi
if grep -qx -- '-D' "$SESSION_TRACE"; then echo 'FAIL: daemon launched after failed check' >&2; exit 1; fi
: > "$SESSION_TRACE"
if JAILBOX_SSH_PROXY_URL=malformed sh "$tmp/start" 2> "$tmp/error"; then
    echo 'FAIL: failed environment producer accepted' >&2; exit 1
fi
[[ ! -s "$SESSION_TRACE" ]]
status=0
JAILBOX_SSH_PROXY_URL='' SESSION_START_STATUS=43 sh "$tmp/start" || status=$?
[[ $status == 43 ]]

# Test the build-time compatibility refusal with both daemon outcomes. The
# wrapper must preserve the underlying diagnostic and name the needed feature.
sed -n '/^if ! sshd -T /,/^fi$/p' "$ROOT/src/container/setup.sh" > "$tmp/feature-check"
[[ -s "$tmp/feature-check" ]]
sshd() { printf 'feature probe diagnostic\n' >&2; return "$FEATURE_STATUS"; }
export -f sshd
export FEATURE_STATUS=0
bash "$tmp/feature-check" > "$tmp/output" 2> "$tmp/error"
export FEATURE_STATUS=1
if bash "$tmp/feature-check" > "$tmp/output" 2> "$tmp/error"; then
    echo 'FAIL: unsupported server accepted' >&2; exit 1
fi
grep -q 'feature probe diagnostic' "$tmp/error"
grep -q 'SetEnv support (OpenSSH 7.8+)' "$tmp/error"
printf 'PASS: SSH proxy startup validates data, clears inherited values, and propagates failures\n'
