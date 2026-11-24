#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
args=" $* "
[[ $args == *' --retry-all-errors '* && $args == *' --retry-max-time 45 '* ]] || exit 90
case "$args" in
    *api.github.com*) response='{"tag_name":"1.2.3"}'; service=github ;;
    *update.code.visualstudio.com*) response='{"productVersion":"1.2.3"}'; service=code ;;
    *marketplace.visualstudio.com*) response='{"results":[{"extensions":[{"versions":[{"version":"1.2.3"}]}]}]}'; service=marketplace ;;
    *open-vsx.org*) response='{"version":"1.2.3"}'; service=openvsx ;;
    *) exit 91 ;;
esac
if [[ ${FAIL_SERVICE:-} == "$service" ]]; then
    echo 'curl: (22) The requested URL returned error: 403' >&2
    exit 22
fi
if [[ ${BAD_SERVICE:-} == "$service" ]]; then response='{}'; fi
printf '%s\n' "$response"
STUB
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
bash "$ROOT/scripts/resolve-updates.sh" --editors > "$tmp/out" 2> "$tmp/err"
grep -q '^CODIUM_VERSION=1.2.3$' "$tmp/out"
grep -q '^OPEN_REMOTE_SSH_VERSION=1.2.3$' "$tmp/out"
# --editors looks up only the editor and extension versions.
[[ $(wc -l < "$tmp/out") -eq 4 ]]
if bash "$ROOT/scripts/resolve-updates.sh" --images > /dev/null 2>&1; then exit 1; fi
for entry in 'github:VSCodium GitHub releases' 'code:VS Code update API' 'marketplace:VS Code Marketplace Remote SSH' 'openvsx:Open VSX Open Remote SSH'; do
    service=${entry%%:*}
    label=${entry#*:}
    if FAIL_SERVICE=$service bash "$ROOT/scripts/resolve-updates.sh" --editors > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
    [[ ! -s $tmp/out ]]
    grep -Fq "could not fetch $label version" "$tmp/err"
    grep -Fq '403' "$tmp/err"
    if BAD_SERVICE=$service bash "$ROOT/scripts/resolve-updates.sh" --editors > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
    [[ ! -s $tmp/out ]]
    grep -Fq "$label returned a response without a valid version" "$tmp/err"
done
printf 'PASS: version lookups identify failures and reject incomplete responses\n'
