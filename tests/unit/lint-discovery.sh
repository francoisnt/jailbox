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
cp "$ROOT/scripts/lib/lint-cache-key.py" "$tmp/scripts/lib/"
cp "$ROOT/tests/lib/"{logging.sh,run-suite.py} "$tmp/tests/lib/"
# shellcheck source=scripts/lib/container-shells.sh
source "$ROOT/scripts/lib/container-shells.sh"
for script in src/jailbox src/public-api.sh src/install.sh tests/run; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/$script"
done
# Discovery and dialect routing do not require repeatedly analyzing miniature
# repositories. Record one complete driver run, including files beyond batch 1.
mkdir "$tmp/bin"
export LINT_INVOCATIONS="$tmp/invocations"
cp "$ROOT/tests/fixtures/lint-shellcheck.sh" "$tmp/bin/shellcheck"
chmod 755 "$tmp/bin/shellcheck"
for script in src/host/core/future.sh src/host/frontend/future.sh \
    src/container/checks/future.sh src/container/checks/extensionless; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/$script"
done
for index in {1..9}; do
    printf '#!/bin/bash\ntrue\n' > "$tmp/tests/future-$index.sh"
done
printf '#!/bin/sh\ntrue\n' > "$tmp/src/container/checks/portable.sh"
PATH="$tmp/bin:$PATH" bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
for script in src/host/core/future.sh src/host/frontend/future.sh \
    src/container/checks/future.sh src/container/checks/extensionless tests/future-9.sh; do
    grep -Eq -- "--shell=bash .*${script//./\\.}($| )" "$LINT_INVOCATIONS" || fail "missed Bash source $script"
done
grep -Eq -- '--shell=sh .*src/container/checks/portable\.sh($| )' "$LINT_INVOCATIONS" || fail 'POSIX script routed as Bash'
grep -Eq -- '--check-sourced --external-sources --shell=bash .*src/jailbox($| )' "$LINT_INVOCATIONS" || fail 'lost entrypoint source analysis'
rm "$tmp/bin/shellcheck"
# Real ShellCheck establishes clean success, output/timings, cache reuse and
# failure propagation below. Its dialect semantics need no per-file retesting.
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
# Reuse success independently of later gate results, but never stale inputs.
bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1
grep -q 'cached identical inputs' "$tmp/output"
cache_key() { (cd "$tmp" && python3 scripts/lib/lint-cache-key.py); }
key_before=$(cache_key)
printf 'documentation only\n' > "$tmp/README.md"
[[ $(cache_key) = "$key_before" ]] || fail 'documentation invalidated cache'
printf '#!/bin/bash\ntrue\n' > "$tmp/tests/cache-source.sh"
key_added=$(cache_key)
[[ -n "$key_added" && "$key_added" != "$key_before" ]] || fail 'new source did not invalidate cache'
mv "$tmp/tests/cache-source.sh" "$tmp/tests/renamed-source.sh"
key_renamed=$(cache_key)
[[ -n "$key_renamed" && "$key_renamed" != "$key_added" ]] || fail 'rename did not invalidate cache'
# Exercise the driver with a formerly successful key and now-invalid content.
printf '%s\n' "$key_renamed" > "$tmp/testlog/shellcheck-cache/success"
# shellcheck disable=SC2016 # Deliberately invalid source after cached success.
printf '#!/bin/bash\nvalue="two words"\necho $value\n' > "$tmp/tests/renamed-source.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'changed source reused old success'; fi
grep -Fq SC2086 "$tmp/output" || fail 'lost real ShellCheck diagnostic'
[[ ! -f "$tmp/testlog/shellcheck-cache/success" ]] || fail 'failed lint retained success'
rm "$tmp/tests/renamed-source.sh"
[[ $(cache_key) = "$key_before" ]] || fail 'deleted source retained in key'
# The initial real pass certified these same inputs. Reuse its marker to check
# option bypass without paying for another identical warm-up analysis.
printf '%s\n' "$key_before" > "$tmp/testlog/shellcheck-cache/success"
bash "$tmp/scripts/lint.sh" --format gcc > "$tmp/output" 2>&1
if grep -q 'cached identical inputs' "$tmp/output"; then fail 'custom flags reused default success'; fi
[[ ! -f "$tmp/testlog/shellcheck-cache/success" ]] || fail 'custom invocation published default success'
printf 'disable=SC2086\n' > "$tmp/.shellcheckrc"
[[ -z $(cache_key) ]] || fail 'custom configuration allowed reuse'
rm "$tmp/.shellcheckrc"
[[ -z $(SHELLCHECK_OPTS=--exclude=SC2086 cache_key) ]] || fail 'custom environment allowed reuse'
[[ -z $(SHELLCHECK_LIB=/tmp cache_key) ]] || fail 'custom library path allowed reuse'
printf '#!/bin/bash\nexec %q "$@"\n' "$(command -v shellcheck)" > "$tmp/bin/shellcheck"
chmod 755 "$tmp/bin/shellcheck"
key_after=$(PATH="$tmp/bin:$PATH" cache_key)
[[ -n "$key_after" && "$key_before" != "$key_after" ]] || fail 'tool identity did not invalidate cache'
printf '%s\n' "$key_before" > "$tmp/testlog/shellcheck-cache/success"
printf 'PASS: lint cache requires successful identical sources, paths, tool and default options\n'
printf 'true\n' > "$tmp/src/container/checks/missing-shell.sh"
if bash "$tmp/scripts/lint.sh" > "$tmp/output" 2>&1; then fail 'missing interpreter escaped lint'; fi
grep -Fq 'unsupported shell shebang' "$tmp/output"
[[ ! -f "$tmp/testlog/shellcheck-cache/success" ]] || fail 'discovery failure retained success'
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
