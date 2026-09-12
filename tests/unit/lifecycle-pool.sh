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

TEST_CASE='all rows, seven fault groups, and targeted failures are scheduled'
lifecycle_jobs > "$TEST_ROOT/catalog"
[[ $(wc -l < "$TEST_ROOT/catalog") = 59 ]]
[[ $(grep -c '^row\.' "$TEST_ROOT/catalog") = 48 ]]
[[ $(grep -c '^fault\.' "$TEST_ROOT/catalog") = 7 ]]
cut -d '|' -f3- "$TEST_ROOT/catalog" | head -48 > "$TEST_ROOT/rows"
lifecycle_matrix_rows > "$TEST_ROOT/expected-rows"
cmp "$TEST_ROOT/expected-rows" "$TEST_ROOT/rows"
lifecycle_fixed_cases | sort > "$TEST_ROOT/fixed"
[[ $(wc -l < "$TEST_ROOT/fixed") = 164 ]]
[[ $(sort -u "$TEST_ROOT/fixed" | wc -l) = 164 ]]
pass

TEST_CASE='history changes ordering without dropping or duplicating jobs'
lifecycle_order_jobs "$TEST_ROOT/catalog" /dev/null > "$TEST_ROOT/ordered"
[[ $(head -7 "$TEST_ROOT/ordered" | grep -c '^fault\.') = 7 ]]
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

# External shells keep errexit active when the parent collects failed workers.
cat > "$TEST_ROOT/worker" <<'WORKER'
#!/bin/bash
set -euo pipefail
source "$1/tests/lib/lifecycle-jobs.sh"
run="$2"
record_job() {
    local IFS='|'
    cat >/dev/null # Must not consume another catalog record.
    if [[ ${POOL_TEST_BARRIER:-false} = true ]]; then
        touch "$run/barrier-$BASHPID"
        local deadline=$((SECONDS + 5))
        while [[ $(find "$run" -name 'barrier-*' | wc -l) -lt 2 ]]; do
            [[ "$SECONDS" -lt "$deadline" ]] || exit 1
            sleep 0.01
        done
    fi
    if [[ "$1" = fail ]]; then false; fi
    printf '%s\n' "$*" >> "$run/visited-$BASHPID"
}
lifecycle_run_queue "$run" record_job
WORKER
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
    [[ $(find "$run/done" -type f | wc -l) = 59 ]]
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
mkdir -p "$tree/tests/lib" "$tree/tests/integration" "$tree/host" "$tree/bin"
cp "$ROOT/tests/integration/lifecycle-state.sh" "$tree/tests/integration/"
cp "$ROOT/tests/lib/"{logging,resource-ledger,lifecycle-matrix,lifecycle-jobs}.sh "$tree/tests/lib/"
cp "$ROOT/host/project-id.sh" "$tree/host/"
cat > "$tree/bin/podman" <<'ENGINE'
#!/bin/bash
set -euo pipefail
[[ "$*" != 'image exists jailbox-test-debian' ]] || exit 0
[[ ${2:-} != exists ]] || exit 1
echo 'Unexpected engine mutation during coordinator test' >&2
exit 97
ENGINE
chmod 755 "$tree/bin/podman"
cat > "$tree/tests/lib/lifecycle-worker.sh" <<'MOCK_WORKER'
#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/tests/lib/lifecycle-matrix.sh"
source "$root/tests/lib/lifecycle-jobs.sh"
source "$root/tests/lib/resource-ledger.sh"
run="$1"; log="$2"
ledger_begin_run mock-worker
printf '%s\n' "$LEDGER_FILE" > "$log/ledger"
printf '%s\n' "$3" > "$log/fixture"
: > "$log/cases"
: > "$log/expected-faults"
complete_job() {
    local kind="$1" key
    shift
    case "$kind" in
        row) for key in up stop --clean; do printf '%s.%s\n' "$1" "$key"; done ;;
        fault)
            printf 'trace.%s.%s\n' "$1" "$2"
            printf 'mkdir /fixture/state\n' > "$log/trace"
            lifecycle_fault_cases "$log/trace" "$1" "$2" | tee -a "$log/expected-faults"
            ;;
        special)
            case "$1" in
                resume) key='^failed-resume\.' ;;
                removal) key='^failed-new-container-cleanup$' ;;
                dependency) key='^failed-create\.' ;;
                inspection) key='^home-inspection\.' ;;
            esac
            lifecycle_fixed_cases | grep -E "$key"
            ;;
    esac | sed 's/$/|0/' >> "$log/cases"
}
lifecycle_run_queue "$run" complete_job </dev/null
MOCK_WORKER
previous=""
for workers in 1 2 4; do
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS="$workers" JAILBOX_LIFECYCLE_TIMINGS=/dev/null \
        bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    run=$(sed -n 's/.*matrix passed; logs: //p' "$tree/output")
    [[ $(wc -l < "$run/completed-cases") = 185 ]]
    if [[ -n "$previous" ]]; then cmp "$previous" "$run/completed-cases"; fi
    previous="$run/completed-cases"
    for file in "$run"/worker-*/fixture; do
        IFS= read -r fixture < "$file"
        [[ ! -e "$fixture" ]]
    done
    [[ $(find "$tree/ledger" -name '*.ledger' | wc -l) = 0 ]]
done
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
mkdir -p "$PROJECT" "$FIXTURE/bin" "$TEST_ROOT/toolroot"
cat > "$TEST_ROOT/toolroot/jailbox" <<'CLI'
#!/bin/bash
set -euo pipefail
grep -Eq "^owner $$ " "$LIFECYCLE_POOL_LEDGER"
CLI
chmod 755 "$TEST_ROOT/toolroot/jailbox"
ROOT="$TEST_ROOT/toolroot"
cli up
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
if lifecycle_fixture_port_available 56216 "$port_proc"; then exit 1; fi
lifecycle_fixture_port_available 62000 "$port_proc"
printf '0: 0100007F:F230 00000000:0000 0A\n' > "$port_proc/net/tcp"
if lifecycle_fixture_port_available 62000 "$port_proc"; then exit 1; fi
: > "$port_proc/net/tcp"
printf '0: 00000000000000000000000000000000:F230 0:0000 0A\n' > "$port_proc/net/tcp6"
if lifecycle_fixture_port_available 62000 "$port_proc"; then exit 1; fi
rm "$port_proc/net/tcp6"
lifecycle_fixture_port_available 62000 "$port_proc"
for port in 65536 00001 bad; do
    if lifecycle_fixture_port_available "$port" "$port_proc"; then exit 1; fi
done
printf 'bad range\n' > "$port_proc/sys/net/ipv4/ip_local_port_range"
if lifecycle_fixture_port_available 62000 "$port_proc"; then exit 1; fi
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
