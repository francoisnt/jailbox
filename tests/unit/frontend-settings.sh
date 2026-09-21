#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/frontend/settings.sh
source "$ROOT/src/host/frontend/settings.sh"
# shellcheck source=tests/lib/file-publication.sh
source "$ROOT/tests/lib/file-publication.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
declare -A EDITOR_CONNECTION=([ssh_config]='/tmp/a "quoted"\path é 😀' [proxy_url]='')
settings=$TMP/profile/User/settings.json
for proxy in '' http://10.0.0.2:8888; do
    EDITOR_CONNECTION[proxy_url]=$proxy
    write_editor_settings "$settings"
    python3 "$ROOT/tests/lib/editor/check-settings.py" "$settings" "${EDITOR_CONNECTION[ssh_config]}" "$proxy"
done
for value in $'/tmp/bad\npath' $'/tmp/\377' $'/tmp/\xc0\x80' $'/tmp/\xed\xa0\x80' $'/tmp/\xf4\x90\x80\x80'; do
    printf 'original\n' > "$settings"
    if (EDITOR_CONNECTION[ssh_config]=$value; write_editor_settings "$settings") > "$TMP/out" 2> "$TMP/err"; then
        fail 'published invalid JSON text'
    fi
    [[ ! -s "$TMP/out" && $(cat "$settings") == original ]]
    [[ -z $(find "$TMP/profile" -name 'settings.json.tmp.*' -print) ]]
done
writer() { write_editor_settings "$settings"; }
assert_file_publication writer "$settings"
printf 'PASS: settings template JSON round trips, input validation, and publication under both umasks\n'
