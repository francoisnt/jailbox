#!/bin/bash
# Exercise the real lint driver against future nested and extensionless scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/scripts" "$tmp/tests" "$tmp/container/checks"
cp "$ROOT/scripts/lint.sh" "$tmp/scripts/"
for script in jailbox install.sh tests/run; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/$script"
done
for name in future.sh extensionless; do
    # shellcheck disable=SC2016 # Deliberately invalid source for the lint fixture.
    printf '#!/bin/bash\nvalue="two words"\necho $value\n' > "$tmp/container/checks/$name"
    if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail "missed $name"; fi
    grep -Fq "container/checks/$name" "$tmp/output"
    grep -Fq SC2086 "$tmp/output"
    rm "$tmp/container/checks/$name"
done
printf '#!/bin/sh\nvalues=(one two)\n' > "$tmp/container/checks/portable.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'POSIX script checked as Bash'; fi
grep -Fq SC3030 "$tmp/output"
printf '#!/bin/sh\ntrue\n' > "$tmp/container/checks/portable.sh"
bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
printf 'true\n' > "$tmp/container/checks/missing-shell.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'missing interpreter escaped lint'; fi
grep -Fq 'unsupported shell shebang' "$tmp/output"
printf 'PASS: nested container scripts are discovered and checked with their declared shell\n'
