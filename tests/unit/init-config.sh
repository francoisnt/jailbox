#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/project"
# A minimal PATH proves initialization has no engine or SSH prerequisite.
for tool in bash dirname readlink realpath mktemp ln rm cat; do
    ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
(cd "$tmp/project" && PATH="$tmp/bin" "$ROOT/jailbox" init)
grep -Fxq READONLY_PATHS= "$tmp/project/jailbox.conf"
cp "$tmp/project/jailbox.conf" "$tmp/original"
if (cd "$tmp/project" && "$ROOT/jailbox" init); then exit 1; fi
cmp "$tmp/original" "$tmp/project/jailbox.conf"
rm "$tmp/project/jailbox.conf"
if (cd "$tmp/project" && "$ROOT/jailbox" --config elsewhere init); then exit 1; fi
[[ ! -e "$tmp/project/jailbox.conf" ]]
printf 'PASS: public init needs no runtime tools, preserves existing files, and rejects selection\n'
