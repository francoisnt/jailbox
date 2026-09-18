#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
terminal() {
    python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$FIXTURE/project" --output "$FIXTURE/shell" "$@"
}
expect_success
before=$(snapshot)
: > "$CONVERGENCE_LOG"
for stream in stdin stdout; do
    terminal --expect refuse "--$stream-pipe" -- "$ROOT/jailbox" shell
    grep -q 'requires a terminal on both stdin and stdout' "$FIXTURE/shell.stderr"
done
for argument in -- --help command ''; do
    terminal --expect refuse -- "$ROOT/jailbox" shell "$argument"
    grep -q 'unexpected argument' "$FIXTURE/shell.stderr"
done
terminal --expect refuse -- "$ROOT/jailbox" --config missing shell
grep -q -- '--config cannot be used with shell' "$FIXTURE/shell.stderr"
# Invalid project configuration and host profiles must not be interpreted.
printf 'not valid file configuration\n' > "$FIXTURE/project/jailbox.conf"
mkdir "$FIXTURE/host-home"
printf 'exit 93\n' > "$FIXTURE/host-home/.bash_profile"
HOME="$FIXTURE/host-home" terminal -- "$ROOT/jailbox" shell
JAILBOX_CONFIG_DEV_IMAGE=private-image-value terminal --expect refuse -- "$ROOT/jailbox" shell
grep -q 'JAILBOX_CONFIG_DEV_IMAGE' "$FIXTURE/shell.stderr"
if grep -q 'private-image-value' "$FIXTURE/shell.stderr"; then fail 'digest diagnostic exposed a value'; fi
# The fake SSH verifies the literal command and supplies an unreachable cwd.
CONVERGENCE_SHELL_DIRECTORY="$FIXTURE/missing" terminal --expect refuse -- "$ROOT/jailbox" shell
grep -q 'No such file or directory' "$FIXTURE/shell.stderr"
assert_no_mutation
"$ROOT/jailbox" --help > "$FIXTURE/help"
grep -q 'shell.*Open an interactive login shell' "$FIXTURE/help"
printf 'PASS: shell TTY preflight, arguments, file isolation, cd failure, and help\n'
