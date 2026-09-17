#!/bin/bash
# Exercise the real lint driver against future nested and extensionless scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/scripts/lib" "$tmp/tests" "$tmp/container/checks" "$tmp/container/runtime/bin" "$tmp/host"
cp "$ROOT/scripts/lint.sh" "$tmp/scripts/"
cp "$ROOT/scripts/build-tarball.sh" "$tmp/scripts/"
cp "$ROOT/scripts/lib/container-shells.sh" "$tmp/scripts/lib/"
# shellcheck source=scripts/lib/container-shells.sh
source "$ROOT/scripts/lib/container-shells.sh"
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
rm "$tmp/container/checks/missing-shell.sh"

# Runtime programs cannot evade either consumer by omitting the .sh suffix.
for contents in '' 'true' '#!/usr/bin/unsupported'; do
    printf '%s' "$contents" > "$tmp/container/runtime/bin/future"
    if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped lint'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    if check_container_syntax "$tmp" > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped syntax check'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    if bash "$tmp/scripts/build-tarball.sh" v9.9.9 > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped packaging'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    [[ ! -e "$tmp/dist" ]]
done

# A valid shebang without a trailing newline must still select its dialect.
for shell in bash sh; do
    printf '#!/bin/%s' "$shell" > "$tmp/container/runtime/bin/future"
    bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
    check_container_syntax "$tmp"
    case "$shell" in
        bash) [[ " ${container_bash[*]} " = *" $tmp/container/runtime/bin/future "* ]] ;;
        sh) [[ " ${container_sh[*]} " = *" $tmp/container/runtime/bin/future "* ]] ;;
    esac
    # Invalid extensionless programs must stop packaging before any artifacts.
    printf '#!/bin/%s\nif\n' "$shell" > "$tmp/container/runtime/bin/future"
    if check_container_syntax "$tmp" > "$tmp/output" 2>&1; then fail 'broken runtime syntax accepted'; fi
    if bash "$tmp/scripts/build-tarball.sh" v9.9.9 > "$tmp/output" 2>&1; then fail 'broken runtime program packaged'; fi
    grep -Fq 'container/runtime/bin/future' "$tmp/output"
    grep -Fq 'invalid container shell source' "$tmp/output"
    [[ ! -e "$tmp/dist" ]]
done
printf 'PASS: nested container scripts are discovered and checked with their declared shell\n'
