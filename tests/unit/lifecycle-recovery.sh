#!/bin/bash
# Sharing a relaunch proof requires an independently verified repaired baseline.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
# shellcheck source=tests/fixtures/lifecycle-recovery.sh
source "$ROOT/tests/fixtures/lifecycle-recovery.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
PREFIX=fixture
NETWORK=fixture-net
HOME_VOLUME=fixture-home
LIFECYCLE_SAMPLE_MODE=true
run_fixture() (
    local key=$1
    FIXTURE="$tmp/$key-${RECOVERY_DAMAGE:-healthy}"
    RUN="$FIXTURE/run" LOG="$FIXTURE/log" STATE="$FIXTURE/state"
    GENERATION="$STATE/ssh-generation" HOME_PATH="$FIXTURE/home"
    mkdir -p "$LOG" "$RUN"
    printf '%s\n' "$key.up" > "$RUN/expected-fixed"
    if [[ ${OMIT_REPRESENTATIVE:-false} = false ]]; then
        printf '%s\n' ssh-mode.up ssh-client-pair.up >> "$RUN/expected-fixed"
    fi
    run_row "$key" plain false false refuse stopped refuse stop keep stopped
)
run_fixture ssh-fifo
printf 'up\nstop\n' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/ssh-fifo-healthy/log/commands"
grep -Fxq 'ssh-fifo.up|ssh-mode.up' "$tmp/ssh-fifo-healthy/log/recovery-coverage"
grep -Fxq 'repaired|stopped|refuse' "$tmp/ssh-fifo-healthy/log/observed"
run_fixture ssh-mode
printf 'up\nstop\nup\n' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/ssh-mode-healthy/log/commands"
grep -Fxq 'recovered|running|allow' "$tmp/ssh-mode-healthy/log/observed"
for RECOVERY_DAMAGE in container home labels unrelated inspection; do
    if run_fixture ssh-pin > "$tmp/error" 2>&1; then
        printf 'FAIL: accepted broken repaired baseline: %s\n' "$RECOVERY_DAMAGE" >&2; exit 1
    fi
    [[ ! -e "$tmp/ssh-pin-$RECOVERY_DAMAGE/log/passed" ]]
done
for leftover in ssh-generation .ssh-generation.interrupted key key.pub known_hosts known_hosts.old ssh_config sshd-runtime; do
    for kind in file directory link; do
        RECOVERY_DAMAGE="ssh-$kind:$leftover"
        if run_fixture ssh-pin > "$tmp/error" 2>&1; then
            printf 'FAIL: accepted leftover SSH material: %s\n' "$RECOVERY_DAMAGE" >&2; exit 1
        fi
        grep -Fq "SSH material survived cleanup:" "$tmp/error"
        [[ ! -e "$tmp/ssh-pin-$RECOVERY_DAMAGE/log/passed" ]]
        [[ ! -e "$tmp/ssh-pin-$RECOVERY_DAMAGE/log/recovery-coverage" ]]
    done
done
unset RECOVERY_DAMAGE
if RECOVERY_DAMAGE=missing-initial-home run_fixture ssh-pin > "$tmp/error" 2>&1; then
    printf 'FAIL: accepted stale labels without an initial home\n' >&2; exit 1
fi
grep -Fq 'retained-home recovery requires initial home labels' "$tmp/error"
[[ ! -e "$tmp/ssh-pin-missing-initial-home/log/commands" ]]
[[ ! -e "$tmp/ssh-pin-missing-initial-home/log/passed" ]]
if OMIT_REPRESENTATIVE=true run_fixture ssh-symlink > "$tmp/error" 2>&1; then
    printf 'FAIL: shared recovery without a selected representative\n' >&2; exit 1
fi
grep -Fq 'required recovery representative is not selected' "$tmp/error"
printf 'PASS: equivalent recovery selection, real relaunch representative, and damaged-baseline negative controls\n'
