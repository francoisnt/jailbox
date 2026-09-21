#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASH_BIN=$(command -v bash)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/project" "$tmp/bin"
for tool in bash dirname basename tr cut sed; do ln -s "$(command -v "$tool")" "$tmp/bin/$tool"; done
if command -v sha256sum >/dev/null; then tool=sha256sum; else tool=shasum; fi
ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
export XDG_STATE_HOME="$tmp/state with spaces"
export JAILBOX_CONFIG_UNKNOWN=invalid
cd "$tmp/project"
# shellcheck source=src/host/core/project-id.sh
source "$ROOT/src/host/core/project-id.sh"
hash=$(jailbox_project_hash_for_path "$PWD")
config="$XDG_STATE_HOME/jailbox/projects/$hash/ssh-generation/ssh_config"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
observe() {
    PATH="$tmp/bin" "$BASH_BIN" "$ROOT/src/jailbox" ssh-config > "$tmp/out" || fail 'instructions require engine, SSH, or policy'
    grep -Fq "Include \"$config\"" "$tmp/out" || fail 'Include is not quoted'
    grep -q 'does not establish safe attachment' "$tmp/out" || fail 'instructions claim health'
    if grep -q 'HostName\|remote.SSH.configFile' "$tmp/out"; then fail 'instructions render guessed policy/editor settings'; fi
}
observe
grep -q 'exists: no' "$tmp/out"
mkdir -p "${config%/*}"
# shellcheck disable=SC2016 # Malicious config must never be read or executed.
printf 'Match exec "touch %s/injected"\n' "$tmp" > "$config"
observe
grep -q 'exists: yes' "$tmp/out"
[[ ! -e "$tmp/injected" ]]
rm "$config"
mkdir "$config"
observe
rmdir "$config"
ln -s nonexistent "$config"
observe
rm "$config"
mkfifo "$config"
observe
for suffix in '$' '%' '*' '?' '[' $'\t' $'\n'; do
    XDG_STATE_HOME="$tmp/$suffix" PATH="$tmp/bin" "$BASH_BIN" "$ROOT/src/jailbox" ssh-config > "$tmp/out"
    grep -q 'cannot be represented safely' "$tmp/out" || fail 'unsafe Include emitted'
    if grep -q '^  Include ' "$tmp/out"; then fail 'unsafe path has Include'; fi
done
if PATH="$tmp/bin" "$BASH_BIN" "$ROOT/src/jailbox" ssh-config extra >/dev/null 2>&1; then fail 'trailing argument accepted'; fi
printf 'PASS: human SSH instructions are safely quoted and never execute configuration\n'
