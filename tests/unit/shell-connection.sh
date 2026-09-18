#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/shell-connection.sh
source "$ROOT/tests/lib/shell-connection.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cp "$ROOT/tests/fixtures/shell/connection-info.sh" "$tmp/cli"
chmod 755 "$tmp/cli"
export SHELL_CONNECTION_REPLY="$tmp/reply" SHELL_CONNECTION_STATUS=0
printf 'ssh_config\t/tmp/config\0ssh_host\tfixture\0remote_path\t/home/jailbox/project\0project_id\t012345abcdef\0' > "$tmp/prefix"
reply() {
    cat "$tmp/prefix" > "$SHELL_CONNECTION_REPLY"
    printf '%b' "$1" >> "$SHELL_CONNECTION_REPLY"
}
read_proxy() { shell_connection_proxy "$tmp" "$tmp/cli" "$tmp/records"; }
reject() {
    local actual
    if actual=$(read_proxy 2> "$tmp/error"); then fail 'accepted invalid or failed connection output'; fi
    [[ -z "$actual" ]] || fail 'published a proxy from invalid or failed output'
}
reply 'proxy_url\thttp://10.241.33.2:8888\0'
[[ $(read_proxy) = http://10.241.33.2:8888 ]] || fail 'lost published proxy URL'
reply 'proxy_url\thttp://999.1.2.3:8888\0'
[[ $(read_proxy) = http://999.1.2.3:8888 ]] || fail 'tightened the production proxy grammar'
for malformed_proxy in 'http://10.241.33.2:8888\n' '\n' \
    'http://10.241.33.2:8888\nevil' 'not-a-url-at-all' 'http://10.241.33.2:9999'; do
    reply "proxy_url\t${malformed_proxy}\0"
    reject
    [[ $(cat "$tmp/error") = 'invalid connection proxy URL' ]] || fail 'missing proxy validation diagnostic'
done
reply 'proxy_url\t\0'
[[ $(read_proxy) = '' ]] || fail 'rejected an explicit unfiltered proxy'
printf 'future_field\topaque\tvalue\n\0' >> "$SHELL_CONNECTION_REPLY"
[[ $(read_proxy) = '' ]] || fail 'rejected a valid trailing extension'
SHELL_CONNECTION_STATUS=42
reject # Complete, plausible unfiltered bytes from a failed producer.
reply 'proxy_url\thttp://10.241.33.2:8888\0'
reject # A nonempty URL must not hide the failed producer either.
SHELL_CONNECTION_STATUS=0
for malformed in '' 'proxy_url' 'proxy_url\t' 'proxy_url\thttp://10.241.33.2:8888' \
    'proxy_url\t\0proxy_url\t\0' 'proxy_url\t\0future\tvalue' \
    'BadName\tvalue\0' 'future\tvalue\0proxy_url\t\0'; do
    reply "$malformed"
    reject
done
: > "$SHELL_CONNECTION_REPLY"
reject
printf 'proxy_url\t\0' > "$SHELL_CONNECTION_REPLY"
reject
printf 'PASS: shell proxy expectations require successful, complete connection records\n'
