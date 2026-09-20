#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=host/frontend/connection.sh
source "$ROOT/host/frontend/connection.sh"
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
records=( $'ssh_config\t/tmp/a "quoted"\\path' $'ssh_host\tjailbox-sample-012345abcdef' $'remote_path\t/home/jailbox/project' $'project_id\t012345abcdef' $'proxy_url\thttp://10.0.0.2:8888' )
write_records() { printf '%s\0' "$@" > "$TMP/records"; }
reject() {
    if parse_connection_records "$TMP/records" > "$TMP/out" 2> "$TMP/err"; then fail 'accepted malformed records'; fi
    [[ ${#EDITOR_CONNECTION[@]} == 0 && ! -s "$TMP/out" && -s "$TMP/err" ]] || fail 'partial connection publication'
}
write_records "${records[@]}"
parse_connection_records "$TMP/records"
[[ ${EDITOR_CONNECTION[ssh_config]} == '/tmp/a "quoted"\path' ]]
write_records "${records[@]}" $'future_field\topaque\tvalue\n\377' $'another\t'
parse_connection_records "$TMP/records"
[[ ${#EDITOR_CONNECTION[@]} == 5 ]]
write_records "${records[@]:0:4}" $'proxy_url\t'
parse_connection_records "$TMP/records"
[[ -z ${EDITOR_CONNECTION[proxy_url]} ]]
for count in 0 1 2 3 4; do
    : > "$TMP/records"
    if ((count)); then write_records "${records[@]:0:count}"; fi
    reject
done
write_records "${records[1]}" "${records[0]}" "${records[@]:2}"; reject
for extra in '' missing_tab $'Bad\tvalue' $'bad-name\tvalue' $'ssh_host\tduplicate' $'x[$(touch marker)]\tbad'; do
    write_records "${records[@]}" "$extra"; reject
done
write_records "${records[@]}" $'future\tone' $'future\ttwo'; reject
write_records "${records[@]}"; printf 'future\tunterminated' >> "$TMP/records"; reject
printf '%s\0' "${records[@]:0:4}" > "$TMP/records"
printf '%s' "${records[4]}" >> "$TMP/records"; reject
for index in 0 1 2 3 4; do
    key=${records[index]%%$'\t'*}
    case "$key" in
        ssh_config|remote_path) invalid=('' relative $'/tmp/bad\npath' $'/tmp/bad\tpath' /) ;;
        ssh_host) invalid=('' '-option' 'bad host' $'bad\177host' 'host;command') ;;
        project_id) invalid=('' ABCDEF012345 012345abcdef0 '../traversal') ;;
        proxy_url) invalid=('https://10.0.0.2:8888' 'http://999.0.0.2:8888' 'http://10.0.0.2:80' 'http://example.com:8888' $'http://10.0.0.2:8888\t') ;;
    esac
    for value in "${invalid[@]}"; do
        altered=("${records[@]}")
        altered[index]=$key$'\t'$value
        write_records "${altered[@]}"; reject
    done
done
printf 'PASS: public connection framing, values, opaque future fields, and atomic parsing\n'
