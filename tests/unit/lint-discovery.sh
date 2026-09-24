#!/bin/bash
# Exercise the real lint driver against future nested and extensionless scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/scripts/lib" "$tmp/tests/lib" "$tmp/src/container/checks" "$tmp/src/container/runtime/bin" "$tmp/src/host/frontend" "$tmp/src/host/core"
cp "$ROOT/scripts/lint.sh" "$tmp/scripts/"
cp "$ROOT/scripts/build-tarball.sh" "$tmp/scripts/"
cp "$ROOT/scripts/lib/container-shells.sh" "$tmp/scripts/lib/"
cp "$ROOT/scripts/lib/process-pool.sh" "$tmp/scripts/lib/"
cp "$ROOT/scripts/lib/worker-resources.sh" "$tmp/scripts/lib/"
cp "$ROOT/tests/lib/"{logging.sh,run-suite.py} "$tmp/tests/lib/"
# shellcheck source=scripts/lib/container-shells.sh
source "$ROOT/scripts/lib/container-shells.sh"
for script in src/jailbox src/public-api.sh src/install.sh tests/run; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/$script"
done
# New modules in either layer must be linted before they are even sourced.
for layer in core frontend; do
    # shellcheck disable=SC2016 # Deliberately invalid fixture source.
    printf '#!/bin/bash\nvalue="two words"\necho $value\n' > "$tmp/src/host/$layer/future.sh"
    if bash "$tmp/scripts/lint.sh" --format gcc > "$tmp/output" 2>&1; then fail "missed $layer module"; fi
    grep -Fq "host/$layer/future.sh" "$tmp/output"
    grep -Fq SC2086 "$tmp/output"
    rm "$tmp/src/host/$layer/future.sh"
done
# A discovered script beyond the first batch must still fail the complete run.
for index in {1..9}; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/tests/future-$index.sh"
done
# shellcheck disable=SC2016 # Deliberately invalid fixture source.
printf '#!/bin/bash\nvalue="two words"\necho $value\n' > "$tmp/tests/future-9.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'missed later test batch'; fi
grep -Fq 'tests/future-9.sh' "$tmp/output"
grep -Fq SC2086 "$tmp/output"
rm "$tmp"/tests/future-*.sh
for name in future.sh extensionless; do
    # shellcheck disable=SC2016 # Deliberately invalid source for the lint fixture.
    printf '#!/bin/bash\nvalue="two words"\necho $value\n' > "$tmp/src/container/checks/$name"
    if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail "missed $name"; fi
    grep -Fq "container/checks/$name" "$tmp/output"
    grep -Fq SC2086 "$tmp/output"
    rm "$tmp/src/container/checks/$name"
done
printf '#!/bin/sh\nvalues=(one two)\n' > "$tmp/src/container/checks/portable.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'POSIX script checked as Bash'; fi
grep -Fq SC3030 "$tmp/output"
printf '#!/bin/sh\ntrue\n' > "$tmp/src/container/checks/portable.sh"
rm -rf "$tmp/testlog"
bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
grep -q 'ShellCheck passed' "$tmp/output"
[[ $(grep -c 'Progress: ShellCheck:' "$tmp/output") -le 1 ]] || fail 'noisy fast lint run'
if grep -Eq 'shellcheck: starting|shellcheck: .*: passed' "$tmp/output"; then fail 'batch chatter on console'; fi
lint_logs=("$tmp"/testlog/shellcheck.*)
[[ ${#lint_logs[@]} = 1 && -d ${lint_logs[0]} ]] || fail 'expected one new lint run'
lint_log=${lint_logs[0]}
[[ -s "$lint_log/timings.log" ]] || fail 'missing detailed timings'
grep -q 'host modules: passed' "$lint_log/timings.log"
printf 'true\n' > "$tmp/src/container/checks/missing-shell.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'missing interpreter escaped lint'; fi
grep -Fq 'unsupported shell shebang' "$tmp/output"
rm "$tmp/src/container/checks/missing-shell.sh"

# Runtime programs cannot evade either consumer by omitting the .sh suffix.
for contents in '' 'true' '#!/usr/bin/unsupported'; do
    printf '%s' "$contents" > "$tmp/src/container/runtime/bin/future"
    if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped lint'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    if check_container_syntax "$tmp/src" > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped syntax check'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    if bash "$tmp/scripts/build-tarball.sh" v9.9.9 > "$tmp/output" 2>&1; then fail 'runtime interpreter escaped packaging'; fi
    grep -Fq 'unsupported shell shebang' "$tmp/output"
    [[ ! -e "$tmp/dist" ]]
done

# A valid shebang without a trailing newline must still select its dialect.
for shell in bash sh; do
    printf '#!/bin/%s' "$shell" > "$tmp/src/container/runtime/bin/future"
    bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
    check_container_syntax "$tmp/src"
    case "$shell" in
        bash) [[ " ${container_bash[*]} " = *" $tmp/src/container/runtime/bin/future "* ]] ;;
        sh) [[ " ${container_sh[*]} " = *" $tmp/src/container/runtime/bin/future "* ]] ;;
    esac
    # Invalid extensionless programs must stop packaging before any artifacts.
    printf '#!/bin/%s\nif\n' "$shell" > "$tmp/src/container/runtime/bin/future"
    if check_container_syntax "$tmp/src" > "$tmp/output" 2>&1; then fail 'broken runtime syntax accepted'; fi
    if bash "$tmp/scripts/build-tarball.sh" v9.9.9 > "$tmp/output" 2>&1; then fail 'broken runtime program packaged'; fi
    grep -Fq 'container/runtime/bin/future' "$tmp/output"
    grep -Fq 'invalid container shell source' "$tmp/output"
    [[ ! -e "$tmp/dist" ]]
done
printf 'PASS: nested container scripts are discovered and checked with their declared shell\n'
