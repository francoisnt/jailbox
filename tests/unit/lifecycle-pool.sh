#!/bin/bash
# Scheduling must preserve membership, propagate failure, and isolate resets.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_CASE=setup
trap 'printf "FAIL [%s] line %s: %s\n" "$TEST_CASE" "$LINENO" "$BASH_COMMAND" >&2' ERR
pass() { printf 'PASS: %s\n' "$TEST_CASE"; }

TEST_CASE='all rows, nine fault groups, and targeted failures are scheduled'
lifecycle_jobs > "$TEST_ROOT/catalog"
[[ $(wc -l < "$TEST_ROOT/catalog") = 61 ]]
[[ $(grep -c '^row\.' "$TEST_ROOT/catalog") = 48 ]]
[[ $(grep -c '^fault\.' "$TEST_ROOT/catalog") = 9 ]]
cut -d '|' -f3- "$TEST_ROOT/catalog" | head -48 > "$TEST_ROOT/rows"
lifecycle_matrix_rows > "$TEST_ROOT/expected-rows"
cmp "$TEST_ROOT/expected-rows" "$TEST_ROOT/rows"
lifecycle_fixed_cases | sort > "$TEST_ROOT/fixed"
[[ $(wc -l < "$TEST_ROOT/fixed") = 166 ]]
[[ $(sort -u "$TEST_ROOT/fixed" | wc -l) = 166 ]]
pass

TEST_CASE='sample membership is exactly the first 50 declared state/command cases'
mkdir "$TEST_ROOT/sample"
cp "$TEST_ROOT/catalog" "$TEST_ROOT/sample/catalog"
lifecycle_select_sample "$TEST_ROOT/sample"
lifecycle_fixed_cases > "$TEST_ROOT/all-fixed"
head -50 "$TEST_ROOT/all-fixed" > "$TEST_ROOT/expected-sample"
cmp "$TEST_ROOT/expected-sample" "$TEST_ROOT/sample/expected-fixed"
[[ $(wc -l < "$TEST_ROOT/sample/catalog") = 17 ]]
[[ $(grep -c '^row\.' "$TEST_ROOT/sample/catalog") = 17 ]]
mkdir "$TEST_ROOT/short-sample"
head -1 "$TEST_ROOT/catalog" > "$TEST_ROOT/short-sample/catalog"
if lifecycle_select_sample "$TEST_ROOT/short-sample" > "$TEST_ROOT/short-out" 2> "$TEST_ROOT/short-err"; then
    echo 'FAIL: incomplete sample accepted' >&2; exit 1
fi
grep -Fq 'Not enough declared cases' "$TEST_ROOT/short-err"
(
    LIFECYCLE_SAMPLE_MODE=true
    while IFS= read -r key; do lifecycle_case_selected "$TEST_ROOT/sample" "$key"; done < "$TEST_ROOT/expected-sample"
    result=0
    lifecycle_case_selected "$TEST_ROOT/sample" inconsistent-digest.--clean || result=$?
    [[ "$result" = 1 ]]
    result=0
    lifecycle_case_selected "$TEST_ROOT/missing" absent.up 2>/dev/null || result=$?
    [[ "$result" = 2 ]]
    LIFECYCLE_SAMPLE_MODE=false
    lifecycle_case_selected "$TEST_ROOT/missing" inconsistent-digest.--clean
)
pass

TEST_CASE='150-case sampling preserves trailing inspection job fields'
mkdir "$TEST_ROOT/extended-sample"
sed 's/^inspection|special|inspection$/&|future-field|/' "$TEST_ROOT/catalog" > "$TEST_ROOT/extended-sample/catalog"
lifecycle_select_sample "$TEST_ROOT/extended-sample" 150
grep -Fxq 'inspection|special|inspection|future-field|' "$TEST_ROOT/extended-sample/catalog"
pass

TEST_CASE='history changes ordering without dropping or duplicating jobs'
lifecycle_order_jobs "$TEST_ROOT/catalog" /dev/null > "$TEST_ROOT/ordered"
[[ $(head -9 "$TEST_ROOT/ordered" | grep -c '^fault\.') = 9 ]]
sort "$TEST_ROOT/catalog" > "$TEST_ROOT/expected"
sort "$TEST_ROOT/ordered" > "$TEST_ROOT/actual"
cmp "$TEST_ROOT/expected" "$TEST_ROOT/actual"
awk -F '|' '{ print $1 "|" ($1 == "row.absent" ? 99 : 1) }' "$TEST_ROOT/catalog" > "$TEST_ROOT/history"
lifecycle_order_jobs "$TEST_ROOT/catalog" "$TEST_ROOT/history" > "$TEST_ROOT/ordered"
[[ $(head -1 "$TEST_ROOT/ordered" | cut -d '|' -f1) = row.absent ]]
sort "$TEST_ROOT/ordered" > "$TEST_ROOT/actual"
cmp "$TEST_ROOT/expected" "$TEST_ROOT/actual"
# shellcheck disable=SC2016 # Deliberately untrusted data, never shell code.
printf 'row.absent|$(touch unwanted)\n' > "$TEST_ROOT/bad-history"
if lifecycle_order_jobs "$TEST_ROOT/catalog" "$TEST_ROOT/bad-history" >/dev/null 2>&1; then
    echo 'FAIL: invalid history accepted' >&2; exit 1
fi
pass

TEST_CASE='discovered allocation faults preserve the intended exception'
printf '%s\n' 'network create one' 'mktemp /state/.ssh-generation.XXXX' 'mkdir /state/server' > "$TEST_ROOT/trace"
lifecycle_fault_cases "$TEST_ROOT/trace" up new-ephemeral > "$TEST_ROOT/faults"
[[ $(wc -l < "$TEST_ROOT/faults") = 8 ]]
grep -Fxq interrupt.up.new-ephemeral.2.barrier "$TEST_ROOT/faults"
if grep -Fxq interrupt.up.new-ephemeral.2.after "$TEST_ROOT/faults"; then exit 1; fi
pass

TEST_CASE='focused fault scenarios retain original trace positions'
printf '%s\n' 'mkdir /state' 'podman start jailbox-project-abc-proxy' \
    'ssh sandbox jailbox-manage-proxy enable url' 'podman start jailbox-project-abc' > "$TEST_ROOT/trace"
lifecycle_fault_cases "$TEST_ROOT/trace" up resume > "$TEST_ROOT/faults"
[[ $(wc -l < "$TEST_ROOT/faults") = 6 ]]
grep -Fxq interrupt.up.resume.2.before "$TEST_ROOT/faults"
grep -Fxq interrupt.up.resume.4.barrier "$TEST_ROOT/faults"
printf '%s\n' 'podman network create --label digest=abc jailbox-project-abc-net' \
    'podman network create --internal jailbox-project-abc-net-internal' 'mkdir /state' > "$TEST_ROOT/trace"
lifecycle_fault_cases "$TEST_ROOT/trace" up plain-network > "$TEST_ROOT/faults"
[[ $(wc -l < "$TEST_ROOT/faults") = 3 ]]
grep -Fxq interrupt.up.plain-network.1.after "$TEST_ROOT/faults"
pass

# External shells keep errexit active when the parent collects failed workers.
cp "$ROOT/tests/fixtures/lifecycle-pool/worker.sh" "$TEST_ROOT/worker"
for workers in 1 2 4; do
    TEST_CASE="$workers workers execute the same complete job set exactly once"
    run="$TEST_ROOT/pool-$workers"
    mkdir -p "$run/claims" "$run/done"
    cp "$TEST_ROOT/ordered" "$run/jobs"
    pids=()
    for ((i=0; i<workers; i++)); do
        bash "$TEST_ROOT/worker" "$ROOT" "$run" </dev/null &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    cat "$run"/visited-* | sort > "$TEST_ROOT/actual"
    cut -d '|' -f2- "$TEST_ROOT/catalog" | sort > "$TEST_ROOT/expected"
    cmp "$TEST_ROOT/expected" "$TEST_ROOT/actual"
    [[ $(find "$run/done" -type f | wc -l) = 61 ]]
    pass
done

TEST_CASE='two workers can make progress concurrently'
run="$TEST_ROOT/concurrent"
mkdir -p "$run/claims" "$run/done"
printf '%s\n' 'one|success' 'two|success' > "$run/jobs"
pids=()
for i in 1 2; do
    POOL_TEST_BARRIER=true bash "$TEST_ROOT/worker" "$ROOT" "$run" </dev/null &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
[[ $(find "$run" -name 'visited-*' | wc -l) = 2 ]]
pass

TEST_CASE='a failed claim cannot be retried or counted as completed'
run="$TEST_ROOT/failure"
mkdir -p "$run/claims" "$run/done"
printf '%s\n' 'bad|fail' 'good|success' > "$run/jobs"
result=0
bash "$TEST_ROOT/worker" "$ROOT" "$run" </dev/null || result=$?
[[ "$result" != 0 && -d "$run/claims/bad" && ! -e "$run/done/bad" ]]
bash "$TEST_ROOT/worker" "$ROOT" "$run" </dev/null
[[ -f "$run/done/good" && ! -e "$run/done/bad" ]]
pass

TEST_CASE='fixture reconstruction removes mutable resources and preserves images and peers'
# shellcheck source=tests/lib/lifecycle-fixture.sh
source "$ROOT/tests/lib/lifecycle-fixture.sh"
FIXTURE="$TEST_ROOT/fixture"
STATE="$FIXTURE/state"
PREFIX=owned
NETWORK=owned-net
HOME_VOLUME=owned-home
EXTRA=owned-extra
mkdir -p "$STATE" "$TEST_ROOT/engine"
printf stale > "$STATE/key"
printf stale > "$FIXTURE/saved-key"
for resource in container.owned container.owned-proxy network.owned-net \
    network.owned-net-internal network.owned-net-external network.owned-extra \
    volume.owned-home image.owned-image image.owned-proxy container.peer volume.peer-home; do
    printf retained > "$TEST_ROOT/engine/$resource"
done
exists() { [[ -f "$TEST_ROOT/engine/$1.$2" ]]; }
podman() {
    printf '%s\n' "$*" >> "$TEST_ROOT/engine-calls"
    case "$1" in
        rm) rm "$TEST_ROOT/engine/container.$3" ;;
        network|volume) rm "$TEST_ROOT/engine/$1.$3" ;;
        unshare) shift; "$@" ;;
        *) echo 'FAIL: unexpected engine operation' >&2; return 1 ;;
    esac
}
reset_fixture
[[ ! -e "$STATE" && ! -e "$FIXTURE/saved-key" ]]
find "$TEST_ROOT/engine" -type f -exec basename {} \; | sort > "$TEST_ROOT/actual"
printf '%s\n' container.peer image.owned-image image.owned-proxy volume.peer-home > "$TEST_ROOT/expected"
cmp "$TEST_ROOT/expected" "$TEST_ROOT/actual"
[[ $(cat "$TEST_ROOT/engine/image.owned-image") = retained ]]
pass

TEST_CASE='the coordinator consolidates complete coverage and cleans every worker'
tree="$TEST_ROOT/coordinator"
mkdir -p "$tree/tests/lib" "$tree/tests/integration" "$tree/src/host" "$tree/bin"
cp "$ROOT/tests/integration/lifecycle-state.sh" "$tree/tests/integration/"
cp "$ROOT/tests/lib/"{logging,resource-ledger,lifecycle-matrix,lifecycle-jobs,lifecycle-contracts,fixture-ports}.sh "$tree/tests/lib/"
cp -R "$ROOT/tests/lib/lifecycle" "$tree/tests/lib/"
# The fake workers never bind sockets. Model their Linux socket tables instead
# of reading the host's /proc, which is absent on macOS. Keep the real selector.
mkdir -p "$tree/proc/sys/net/ipv4" "$tree/proc/net"
printf '32768 60999\n' > "$tree/proc/sys/net/ipv4/ip_local_port_range"
: > "$tree/proc/net/tcp"
: > "$tree/proc/net/tcp6"
sed "s|/proc}|$tree/proc}|" "$ROOT/tests/lib/fixture-ports.sh" > "$tree/tests/lib/fixture-ports.sh"
grep -Fq "$tree/proc}" "$tree/tests/lib/fixture-ports.sh"
mkdir -p "$tree/src/host/core"
cp "$ROOT/src/public-api.sh" "$tree/src/"
cp "$ROOT/src/host/api-support.sh" "$tree/src/host/"
cp "$ROOT/src/host/core/project-id.sh" "$tree/src/host/core/"
cp "$ROOT/tests/fixtures/lifecycle-pool/podman.sh" "$tree/bin/podman"
chmod 755 "$tree/bin/podman"
# This fixture exercises coordination and ownership, not Linux process-group
# isolation. Supply its platform prerequisites on every portable host, including
# macOS, without depending on a host setsid installation.
cat > "$tree/bin/setsid" <<'SESSION'
#!/bin/bash
exec "$@"
SESSION
cat > "$tree/bin/uname" <<'PLATFORM'
#!/bin/bash
[[ "$*" = -s ]] || exit 97
printf 'Linux\n'
PLATFORM
chmod 755 "$tree/bin/setsid" "$tree/bin/uname"
cp "$ROOT/tests/fixtures/lifecycle-pool/mock-worker.sh" "$tree/tests/lib/lifecycle-worker.sh"
TEST_CASE='invalid mappings fail before coordinator resource preparation'
cp "$tree/tests/lib/lifecycle-contracts.sh" "$tree/contracts-backup"
for mapping in LIFECYCLE_COMMAND_CONTRACTS LIFECYCLE_FAULT_SCENARIOS; do
    cp "$tree/contracts-backup" "$tree/tests/lib/lifecycle-contracts.sh"
    printf '\nunset "%s[up]"\n' "$mapping" >> "$tree/tests/lib/lifecycle-contracts.sh"
    if PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS=1 bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        echo 'FAIL: incomplete mapping accepted' >&2; exit 1
    fi
    grep -q "missing mapping 'up'" "$tree/output"
    [[ ! -e "$tree/testlog" && ! -e "$tree/ledger" ]]
done
cp "$tree/contracts-backup" "$tree/tests/lib/lifecycle-contracts.sh"
pass
TEST_CASE='the coordinator consolidates complete coverage and cleans every worker'
previous=""
for workers in 1 2 4; do
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS="$workers" JAILBOX_LIFECYCLE_TIMINGS=/dev/null \
        bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    run=$(sed -n 's/.*matrix passed; logs: //p' "$tree/output")
    [[ $(wc -l < "$run/completed-cases") = 187 ]]
    grep -Fxq "workers=$workers" "$run/run-summary"
    grep -Eq '^elapsed_seconds=[0-9]+$' "$run/run-summary"
    grep -Fxq 'exit_status=0' "$run/run-summary"
    if [[ -n "$previous" ]]; then cmp "$previous" "$run/completed-cases"; fi
    previous="$run/completed-cases"
    for file in "$run"/worker-*/fixture; do
        IFS= read -r fixture < "$file"
        [[ ! -e "$fixture" ]]
    done
    [[ $(find "$tree/ledger" -name '*.ledger' | wc -l) = 0 ]]
done
pass

TEST_CASE='sample coordinator verifies 50 and 150 cases and cleans up'
for sample_run in 50:1 50:4 50:8 150:1 150:4 150:8; do
    size=${sample_run%:*}
    workers=${sample_run#*:}
    jobs=17
    cp "$TEST_ROOT/expected-sample" "$TEST_ROOT/current-sample"
    if [[ "$size" = 150 ]]; then
        jobs=49
        lifecycle_fixed_cases > "$TEST_ROOT/all-fixed"
        head -144 "$TEST_ROOT/all-fixed" > "$TEST_ROOT/current-sample"
        grep '^home-inspection\.' "$TEST_ROOT/all-fixed" >> "$TEST_ROOT/current-sample"
    fi
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS="$workers" JAILBOX_LIFECYCLE_TIMINGS=/missing-history \
        bash "$tree/tests/integration/lifecycle-state.sh" "--sample-$size" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    run=$(sed -n 's/.*sample passed (partial coverage); logs: //p' "$tree/output")
    [[ $(wc -l < "$run/completed-cases") = "$size" ]]
    LC_ALL=C sort "$TEST_ROOT/current-sample" > "$TEST_ROOT/sorted-sample"
    cmp "$TEST_ROOT/sorted-sample" "$run/completed-cases"
    sort "$run/catalog" > "$TEST_ROOT/sample-catalog-sorted"
    sort "$run/jobs" > "$TEST_ROOT/sample-jobs-sorted"
    cmp "$TEST_ROOT/sample-catalog-sorted" "$TEST_ROOT/sample-jobs-sorted"
    if [[ "$size" = 150 ]]; then
        [[ $(head -1 "$run/jobs") = 'inspection|special|inspection' ]]
    fi
    [[ $(wc -l < "$run/completed-jobs") = "$jobs" ]]
    grep -Fxq "workers=$workers" "$run/sample-summary"
    grep -Eq '^elapsed_seconds=[0-9]+$' "$run/sample-summary"
    grep -Fxq 'exit_status=0' "$run/sample-summary"
    if grep -q 'constructed-state matrix passed' "$tree/output"; then exit 1; fi
    for file in "$run"/worker-*/fixture; do
        IFS= read -r fixture < "$file"
        [[ ! -e "$fixture" ]]
    done
    [[ $(find "$tree/ledger" -name '*.ledger' | wc -l) = 0 ]]
done
pass

TEST_CASE='the actual row runner skips unselected commands before constructing resources'
(
    # shellcheck source=tests/lib/lifecycle-runtime.sh
    source "$ROOT/tests/lib/lifecycle-runtime.sh"
    LIFECYCLE_SAMPLE_MODE=true
    # shellcheck disable=SC2030 # This row-selection fixture is intentionally isolated.
    RUN="$TEST_ROOT/skip-row"
    mkdir "$RUN"
    printf 'absent.up\n' > "$RUN/expected-fixed"
    construct() { echo 'FAIL: unselected row constructed resources' >&2; exit 1; }
    matrix_case_begin() { echo 'FAIL: unselected case was started' >&2; exit 1; }
    run_row running plain false false success running healthy allow none keep stopped
)
pass

TEST_CASE='CLI ownership reaches both ledgers before command execution'
# shellcheck source=tests/lib/resource-ledger.sh
source "$ROOT/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
export JAILBOX_TEST_LEDGER_DIR="$TEST_ROOT/ledger"
ledger_begin_run pool-test
export LIFECYCLE_POOL_LEDGER="$LEDGER_FILE"
ledger_begin_run worker-test
FIXTURE="$TEST_ROOT/cli-fixture"
PROJECT="$FIXTURE/project"
mkdir -p "$PROJECT" "$FIXTURE/bin" "$TEST_ROOT/toolroot/src"
cat > "$TEST_ROOT/toolroot/src/jailbox" <<'CLI'
#!/bin/bash
set -euo pipefail
grep -Eq "^owner $$ " "$LIFECYCLE_POOL_LEDGER"
CLI
chmod 755 "$TEST_ROOT/toolroot/src/jailbox"
ROOT="$TEST_ROOT/toolroot"
PATH="$tree/bin:$PATH" cli up
grep '^owner ' "$LIFECYCLE_POOL_LEDGER" > "$TEST_ROOT/pool-owner"
grep '^owner ' "$LEDGER_FILE" > "$TEST_ROOT/worker-owner"
cmp "$TEST_ROOT/pool-owner" "$TEST_ROOT/worker-owner"
pass

TEST_CASE='automatic worker count obeys CPU, memory, reserve and bounds'
[[ $(lifecycle_worker_budget 16 $((64 * 1048576))) = 8 ]]
[[ $(lifecycle_worker_budget 32 $((16 * 1048576))) = 7 ]]
[[ $(lifecycle_worker_budget 64 $((128 * 1048576))) = 16 ]]
[[ $(lifecycle_worker_budget 1 0) = 1 ]]
[[ $(lifecycle_worker_budget 8 $((5 * 1048576 - 1))) = 1 ]]
[[ $(lifecycle_worker_budget 8 $((9 * 1048576))) = 4 ]]
pass

TEST_CASE='fixture ports avoid outbound ephemeral allocation and existing IPv4/IPv6 sockets'
port_proc="$TEST_ROOT/port-proc"
mkdir -p "$port_proc/sys/net/ipv4" "$port_proc/net"
printf '32768 60999\n' > "$port_proc/sys/net/ipv4/ip_local_port_range"
: > "$port_proc/net/tcp"
: > "$port_proc/net/tcp6"
if test_fixture_port_available 56216 "$port_proc"; then exit 1; fi
test_fixture_port_available 62000 "$port_proc"
printf '0: 0100007F:F230 00000000:0000 0A\n' > "$port_proc/net/tcp"
if test_fixture_port_available 62000 "$port_proc"; then exit 1; fi
: > "$port_proc/net/tcp"
printf '0: 00000000000000000000000000000000:F230 0:0000 0A\n' > "$port_proc/net/tcp6"
if test_fixture_port_available 62000 "$port_proc"; then exit 1; fi
rm "$port_proc/net/tcp6"
test_fixture_port_available 62000 "$port_proc"
for port in 65536 00001 bad; do
    if test_fixture_port_available "$port" "$port_proc"; then exit 1; fi
done
printf 'bad range\n' > "$port_proc/sys/net/ipv4/ip_local_port_range"
if test_fixture_port_available 62000 "$port_proc"; then exit 1; fi
pass

TEST_CASE='resource detection respects affinity and nested cgroup headroom'
proc="$TEST_ROOT/proc"
cgroup="$TEST_ROOT/cgroup"
mkdir -p "$proc/self" "$cgroup/parent/child"
printf 'MemAvailable: 67108864 kB\n' > "$proc/meminfo"
printf '0::/parent/child\n' > "$proc/self/cgroup"
printf 'max 100000\n' > "$cgroup/parent/child/cpu.max"
printf '600000 100000\n' > "$cgroup/parent/cpu.max"
printf 'max\n' > "$cgroup/parent/child/memory.max"
printf '%s\n' "$((12 * 1073741824))" > "$cgroup/parent/memory.max"
printf '%s\n' "$((2 * 1073741824))" > "$cgroup/parent/memory.current"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = "6|$((10 * 1048576))" ]]
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 2) = "2|$((10 * 1048576))" ]]
printf '150000 100000\n' > "$cgroup/cpu.max"
printf '%s\n' "$((8 * 1073741824))" > "$cgroup/memory.max"
printf '%s\n' "$((4 * 1073741824))" > "$cgroup/memory.current"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = "1|$((4 * 1048576))" ]]
printf 'MemAvailable: 1048576 kB\n' > "$proc/meminfo"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|1048576' ]]
pass

TEST_CASE='unknown resource data and exhausted cgroups select one worker'
printf 'unknown\n' > "$proc/meminfo"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf 'MemAvailable: 67108864 kB\n' > "$proc/meminfo"
printf '%s\n' "$((9 * 1073741824))" > "$cgroup/memory.current"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf 'garbage\n' > "$cgroup/memory.max"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf '0::/../../outside\n' > "$proc/self/cgroup"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf '2:memory:/legacy\n' > "$proc/self/cgroup"
[[ $(lifecycle_worker_resources "$proc" "$cgroup" 16) = '1|0' ]]
pass
