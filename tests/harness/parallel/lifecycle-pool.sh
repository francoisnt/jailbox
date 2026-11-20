#!/bin/bash
# Scheduling must preserve membership, propagate failure, and isolate resets.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source=tests/lib/lifecycle-matrix.sh
source "$ROOT/tests/lib/lifecycle-matrix.sh"
# shellcheck source=tests/lib/lifecycle-jobs.sh
source "$ROOT/tests/lib/lifecycle-jobs.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_CASE=setup
trap 'printf "FAIL [%s] line %s: %s\n" "$TEST_CASE" "$LINENO" "$BASH_COMMAND" >&2' ERR
pass() { printf 'PASS: %s\n' "$TEST_CASE"; }

TEST_CASE='declared rows and fault groups are scheduled without duplicates'
lifecycle_jobs > "$TEST_ROOT/catalog"
grep '^row\.' "$TEST_ROOT/catalog" > "$TEST_ROOT/rows"
lifecycle_matrix_rows | sed 's/^[^|]*/row.&|row|&/' > "$TEST_ROOT/expected-rows"
cmp "$TEST_ROOT/expected-rows" "$TEST_ROOT/rows"
for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
    read -r -a scenarios <<< "${LIFECYCLE_FAULT_SCENARIOS[$command]}"
    for scenario in "${scenarios[@]}"; do
        pieces=${LIFECYCLE_FAULT_PIECES[$command:$scenario]-}
        if [[ -z "$pieces" ]]; then
            printf 'fault.%s.%s|fault|%s|%s\n' "$command" "$scenario" "$command" "$scenario"
            continue
        fi
        for ((piece=1; piece<=pieces; piece++)); do
            printf 'fault.%s.%s.p%s|fault|%s|%s|%s|%s\n' "$command" "$scenario" "$piece" \
                "$command" "$scenario" "$piece" "$pieces"
        done
    done
done > "$TEST_ROOT/expected-fault-jobs"
# The four longest sweeps stay split; changing that is a deliberate decision.
[[ $(grep -c '\.p[1-9]|' "$TEST_ROOT/expected-fault-jobs") = 12 ]]
grep '^fault\.' "$TEST_ROOT/catalog" > "$TEST_ROOT/fault-jobs"
cmp "$TEST_ROOT/expected-fault-jobs" "$TEST_ROOT/fault-jobs"
cut -d '|' -f1 "$TEST_ROOT/catalog" | LC_ALL=C sort > "$TEST_ROOT/job-ids"
[[ -z $(uniq -d "$TEST_ROOT/job-ids") ]]
pass

TEST_CASE='sample membership is exactly the first 50 declared state/command cases'
mkdir "$TEST_ROOT/sample"
cp "$TEST_ROOT/catalog" "$TEST_ROOT/sample/catalog"
lifecycle_select_sample "$TEST_ROOT/sample"
lifecycle_fixed_cases > "$TEST_ROOT/all-fixed"
while IFS='|' read -r row _; do
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        printf '%s.%s\n' "$row" "$command"
    done
done < <(lifecycle_matrix_rows) > "$TEST_ROOT/benchmark-rows"
head -50 "$TEST_ROOT/benchmark-rows" > "$TEST_ROOT/expected-sample"
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

TEST_CASE='standalone SSH cleanup is limited to distinct filesystem damage'
for damage in missing symlink directory fifo parent-mode; do
    printf '%s\n' "ssh-$damage.stop" "ssh-$damage.--clean"
done | LC_ALL=C sort > "$TEST_ROOT/expected-ssh-cleanup"
grep -E '^ssh-.*\.(stop|--clean)$' "$TEST_ROOT/all-fixed" | LC_ALL=C sort > "$TEST_ROOT/ssh-cleanup"
cmp "$TEST_ROOT/expected-ssh-cleanup" "$TEST_ROOT/ssh-cleanup"
grep '^ssh-.*\.up$' "$TEST_ROOT/all-fixed" > "$TEST_ROOT/ssh-launches"
lifecycle_matrix_rows | sed -n 's/^\(ssh-[^|]*\)|.*/\1.up/p' > "$TEST_ROOT/expected-ssh-launches"
cmp "$TEST_ROOT/expected-ssh-launches" "$TEST_ROOT/ssh-launches"
while IFS='|' read -r row _; do
    [[ "$row" = ssh-* ]] || continue
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        if grep -Fxq -- "$row.$command" "$TEST_ROOT/all-fixed"; then
            lifecycle_case_selected "$TEST_ROOT" "$row.$command"
        else
            result=0
            lifecycle_case_selected "$TEST_ROOT" "$row.$command" || result=$?
            [[ "$result" = 1 ]]
        fi
    done
done < <(lifecycle_matrix_rows)
pass

TEST_CASE='150-case sample keeps its benchmark cases and trailing inspection job fields'
mkdir "$TEST_ROOT/extended-sample"
sed 's/^inspection|special|inspection$/&|future-field|/' "$TEST_ROOT/catalog" > "$TEST_ROOT/extended-sample/catalog"
lifecycle_select_sample "$TEST_ROOT/extended-sample" 150
grep -Fxq 'inspection|special|inspection|future-field|' "$TEST_ROOT/extended-sample/catalog"
grep -Fxq 'ssh-pin.--clean' "$TEST_ROOT/extended-sample/expected-fixed"
pass

TEST_CASE='history changes ordering without dropping or duplicating jobs'
lifecycle_order_jobs "$TEST_ROOT/catalog" /dev/null > "$TEST_ROOT/ordered"
awk '/^fault\./ { if (other_job) exit 1; next } { other_job = 1 }' "$TEST_ROOT/ordered"
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

TEST_CASE='shards cover every job and fixed case exactly once whatever the timings'
lifecycle_fixed_cases > "$TEST_ROOT/shard-all-fixed"
cut -d '|' -f1 "$TEST_ROOT/catalog" | awk '{ print $1 "|" NR }' > "$TEST_ROOT/ascending-history"
for history in "$ROOT/tests/lib/lifecycle/timings" /dev/null "$TEST_ROOT/ascending-history"; do
    for count in 1 2 3 4 6; do
        : > "$TEST_ROOT/shard-jobs"
        : > "$TEST_ROOT/shard-fixed"
        for ((shard=1; shard<=count; shard++)); do
            run="$TEST_ROOT/shard-$count-$shard"
            rm -rf -- "$run"
            mkdir "$run"
            cp "$TEST_ROOT/catalog" "$run/catalog"
            cp "$TEST_ROOT/shard-all-fixed" "$run/expected-fixed"
            lifecycle_select_shard "$run" "$shard" "$count" "$history"
            [[ -s "$run/catalog" ]]
            cat "$run/catalog" >> "$TEST_ROOT/shard-jobs"
            cat "$run/expected-fixed" >> "$TEST_ROOT/shard-fixed"
        done
        sort "$TEST_ROOT/shard-jobs" > "$TEST_ROOT/actual"
        cmp "$TEST_ROOT/expected" "$TEST_ROOT/actual"
        sort "$TEST_ROOT/shard-fixed" > "$TEST_ROOT/actual"
        sort "$TEST_ROOT/shard-all-fixed" > "$TEST_ROOT/expected-fixed-sorted"
        cmp "$TEST_ROOT/expected-fixed-sorted" "$TEST_ROOT/actual"
    done
done
# A fixed case without an owning catalog job fails instead of disappearing.
for orphan in orphan unknown-row.up trace.up.unknown; do
    run="$TEST_ROOT/shard-orphan"
    rm -rf -- "$run"
    mkdir "$run"
    cp "$TEST_ROOT/catalog" "$run/catalog"
    { cat "$TEST_ROOT/shard-all-fixed"; printf '%s\n' "$orphan"; } > "$run/expected-fixed"
    if lifecycle_select_shard "$run" 1 2 /dev/null 2>/dev/null; then
        echo "FAIL: unowned case $orphan accepted" >&2; exit 1
    fi
done
pass

TEST_CASE='pieces of a split sweep together run exactly the unsplit cases'
for scenario in up:false up:none --clean:false stop:true; do
    command=${scenario%:*}; policy=${scenario#*:}
    trace="$ROOT/tests/fixtures/lifecycle-matrix/up.trace"
    [[ "$command" = up ]] || trace="$ROOT/tests/fixtures/lifecycle-matrix/cleanup.trace"
    lifecycle_fault_cases "$trace" "$command" "$policy" > "$TEST_ROOT/whole"
    [[ -s "$TEST_ROOT/whole" || "$policy" = true ]]
    for pieces in 2 3; do
        : > "$TEST_ROOT/pieces"
        for ((piece=1; piece<=pieces; piece++)); do
            lifecycle_fault_cases "$trace" "$command" "$policy" "$piece" "$pieces" > "$TEST_ROOT/piece-$piece"
            cat "$TEST_ROOT/piece-$piece" >> "$TEST_ROOT/pieces"
        done
        sort "$TEST_ROOT/whole" > "$TEST_ROOT/expected-pieces"
        sort "$TEST_ROOT/pieces" > "$TEST_ROOT/actual"
        cmp "$TEST_ROOT/expected-pieces" "$TEST_ROOT/actual"
        [[ -z $(uniq -d "$TEST_ROOT/actual") ]]
        # Pieces differ by at most one step (three cases), and each takes a
        # contiguous share: every step of a piece precedes the next piece's.
        sizes=$(for ((piece=1; piece<=pieces; piece++)); do wc -l < "$TEST_ROOT/piece-$piece"; done | sort -n)
        (( $(tail -1 <<< "$sizes") - $(head -1 <<< "$sizes") <= 3 ))
        for ((piece=2; piece<=pieces; piece++)); do
            previous=$(cut -d . -f4 "$TEST_ROOT/piece-$((piece - 1))" | sort -n | tail -1)
            next=$(cut -d . -f4 "$TEST_ROOT/piece-$piece" | sort -n | head -1)
            [[ -z "$previous" || -z "$next" || "$previous" -lt "$next" ]]
        done
    done
done
for piece_args in '0 2' '3 2' '1 0' 'x 2'; do
    read -r piece pieces <<< "$piece_args"
    if lifecycle_fault_cases "$trace" up false "$piece" "$pieces" >/dev/null 2>&1; then
        echo "FAIL: invalid piece $piece_args accepted" >&2; exit 1
    fi
done
pass

TEST_CASE='split sweep declarations are validated'
for declaration in '[up:missing]=2' '[up:false]=1' '[up:false]=10' '[unknown:false]=2'; do
    if (
        eval "LIFECYCLE_FAULT_PIECES=($declaration)"
        validate_lifecycle_contracts
    ) > "$TEST_ROOT/pieces-error" 2>&1; then
        echo "FAIL: invalid split $declaration accepted" >&2; exit 1
    fi
    grep -Eq 'split fault scenario|invalid piece count' "$TEST_ROOT/pieces-error"
done
pass

TEST_CASE='pieces of a split sweep must record the same operations in the same order'
run="$TEST_ROOT/piece-traces"
mkdir -p "$run/worker-1/trace.up.false.p1" "$run/worker-2/trace.up.false.p2" "$run/worker-2/trace.up.none"
# Two workers' real traces differ only in fixture, hashes, subnet, port and staging names.
piece_trace() {
    printf '%s\n' \
        "podman network create --internal --subnet 10.240.$2.0/24 jailbox-project-$3-net-internal" \
        "mkdir -p -- /tmp/jailbox-e2e-lifecycle.$1/state/jailbox/projects/$3" \
        "chmod 644 /tmp/jailbox-e2e-lifecycle.$1/state/jailbox/projects/$3/tinyproxy-filter" \
        "chmod 644 /tmp/jailbox-e2e-lifecycle.$1/state/jailbox/projects/$3/tinyproxy.conf" \
        "mktemp -d /tmp/jailbox-e2e-lifecycle.$1/state/.ssh-generation.$4" \
        "podman run -d --name jailbox-project-$3 -p 127.0.0.1:$5:2222 --label jailbox.config-digest=${3}${3}"
}
piece_trace AAAA1111 21 0123456789ab Xy12 63213 > "$run/worker-1/trace.up.false.p1/events"
piece_trace BBBB2222 99 ba9876543210 Qr34 61901 > "$run/worker-2/trace.up.false.p2/events"
printf 'unrelated\n' > "$run/worker-2/trace.up.none/events"
printf '%s\n' 'row.absent|row|absent|plain|none|false|success|absent|refuse|none|new|absent' \
    'fault.up.false.p1|fault|up|false|1|2' 'fault.up.false.p2|fault|up|false|2|2' \
    'fault.up.none|fault|up|none' > "$run/catalog"
lifecycle_check_piece_traces "$run"
# Every piece in the catalog must have left exactly one trace.
mv "$run/worker-2/trace.up.false.p2" "$run/missing-p2"
if lifecycle_check_piece_traces "$run" 2> "$TEST_ROOT/piece-error"; then
    echo 'FAIL: a missing piece trace was accepted' >&2; exit 1
fi
grep -Fq 'Expected exactly one recorded trace for fault.up.false.p2' "$TEST_ROOT/piece-error"
mkdir -p "$run/worker-3/trace.up.false.p2"
cp "$run/missing-p2/events" "$run/worker-3/trace.up.false.p2/events"
mv "$run/missing-p2" "$run/worker-2/trace.up.false.p2"
if lifecycle_check_piece_traces "$run" 2> "$TEST_ROOT/piece-error"; then
    echo 'FAIL: a duplicated piece trace was accepted' >&2; exit 1
fi
grep -Fq 'Expected exactly one recorded trace for fault.up.false.p2' "$TEST_ROOT/piece-error"
rm -r -- "$run/worker-3"
lifecycle_check_piece_traces "$run"
# Pieces on different shards are checked together: each shard's run lists only
# its own pieces, and a piece's trace may be in any of the runs.
other="$TEST_ROOT/piece-traces-other"
mkdir -p "$other/worker-1"
mv "$run/worker-2/trace.up.false.p2" "$other/worker-1/"
grep -v '^fault.up.false.p2|' "$run/catalog" > "$TEST_ROOT/catalog-first"
mv "$TEST_ROOT/catalog-first" "$run/catalog"
printf '%s\n' 'fault.up.false.p2|fault|up|false|2|2' > "$other/catalog"
lifecycle_check_piece_traces "$run"
lifecycle_check_piece_traces "$other"
lifecycle_check_piece_traces "$run" "$other"
[[ -f "$run/piece-trace.up.false.p2" ]]
cp "$other/worker-1/trace.up.false.p2/events" "$TEST_ROOT/p2-events"
sed 's/tinyproxy.conf/other.conf/' "$TEST_ROOT/p2-events" > "$other/worker-1/trace.up.false.p2/events"
if lifecycle_check_piece_traces "$run" "$other" 2> "$TEST_ROOT/piece-error"; then
    echo 'FAIL: mismatched pieces on different shards accepted' >&2; exit 1
fi
grep -Fq 'Pieces of the up.false sweep recorded different operations' "$TEST_ROOT/piece-error"
mkdir -p "$run/worker-2/trace.up.false.p2"
cp "$TEST_ROOT/p2-events" "$run/worker-2/trace.up.false.p2/events"
cp "$TEST_ROOT/p2-events" "$other/worker-1/trace.up.false.p2/events"
if lifecycle_check_piece_traces "$run" "$other" 2> "$TEST_ROOT/piece-error"; then
    echo 'FAIL: a piece traced on two shards was accepted' >&2; exit 1
fi
grep -Fq 'Expected exactly one recorded trace for fault.up.false.p2' "$TEST_ROOT/piece-error"
rm -r -- "$other"
printf '%s\n' 'fault.up.false.p2|fault|up|false|2|2' >> "$run/catalog"
lifecycle_check_piece_traces "$run"
# A swap of two same-kind steps, a changed operand, a missing step, or a
# different operation must each be rejected.
# shellcheck disable=SC2016 # Literal sed expressions.
for change in '3{h;d;};4{G;}' 's/tinyproxy.conf/other.conf/' '$d' '1s/network create/volume create/'; do
    piece_trace BBBB2222 99 ba9876543210 Qr34 61901 | sed "$change" > "$run/worker-2/trace.up.false.p2/events"
    if lifecycle_check_piece_traces "$run" 2> "$TEST_ROOT/piece-error"; then
        echo "FAIL: mismatched piece traces accepted ($change)" >&2; exit 1
    fi
    grep -Fq 'Pieces of the up.false sweep recorded different operations' "$TEST_ROOT/piece-error"
done
pass

TEST_CASE='discovered allocation faults preserve the intended exception'
printf '%s\n' 'network create one' 'mktemp /state/.ssh-generation.XXXX' 'mkdir /state/server' > "$TEST_ROOT/trace"
lifecycle_fault_cases "$TEST_ROOT/trace" up none > "$TEST_ROOT/faults"
[[ $(wc -l < "$TEST_ROOT/faults") = 8 ]]
grep -Fxq interrupt.up.none.2.barrier "$TEST_ROOT/faults"
if grep -Fxq interrupt.up.none.2.after "$TEST_ROOT/faults"; then exit 1; fi
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

TEST_CASE='ephemeral sweeps retain all three faults at the selected operations'
printf '%s\n' 'podman run -d --name jailbox-project-abc-proxy' \
    'podman volume create --label policy jailbox-project-abc-home' \
    'podman run -d --name jailbox-project-abc --cidfile /state/container-id' > "$TEST_ROOT/launch-trace"
printf '%s\n' 'podman rm jailbox-project-abc' 'podman volume rm jailbox-project-abc-home' \
    'rm -rf -- /state/ssh-generation /state/key' 'rm -rf -- /state/jailbox/projects/abc' > "$TEST_ROOT/cleanup-trace"
for command in up stop --clean; do
    case "$command" in
        up) trace=launch-trace; policy=new-ephemeral; points=(2 3) ;;
        stop) trace=cleanup-trace; policy=true; points=(2 3) ;;
        --clean) trace=cleanup-trace; policy=true; points=(2) ;;
    esac
    for point in "${points[@]}"; do
        for fault in before after barrier; do
            printf 'interrupt.%s.%s.%s.%s\n' "$command" "$policy" "$point" "$fault"
        done
    done > "$TEST_ROOT/expected-faults"
    lifecycle_fault_cases "$TEST_ROOT/$trace" "$command" "$policy" > "$TEST_ROOT/faults"
    cmp "$TEST_ROOT/expected-faults" "$TEST_ROOT/faults"
done
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
    find "$run/done" -type f -exec basename {} \; | LC_ALL=C sort > "$TEST_ROOT/completed-jobs"
    cmp "$TEST_ROOT/job-ids" "$TEST_ROOT/completed-jobs"
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

TEST_CASE='after a recorded failure, workers finish their current job and claim no more'
run="$TEST_ROOT/stop"
mkdir -p "$run/claims" "$run/done"
printf '%s\n' 'first|success' 'second|halt' 'third|success' > "$run/jobs"
bash "$TEST_ROOT/worker" "$ROOT" "$run" </dev/null
printf '%s\n' success halt > "$TEST_ROOT/expected-visits"
cat "$run"/visited-* > "$TEST_ROOT/actual-visits"
cmp "$TEST_ROOT/expected-visits" "$TEST_ROOT/actual-visits"
[[ -f "$run/done/second" && ! -e "$run/done/third" ]]
# A stop recorded between reading a job and claiming it still prevents the start.
run="$TEST_ROOT/stop-race"
mkdir -p "$run/claims" "$run/done"
printf '%s\n' 'raced|success' > "$run/jobs"
(
    mkdir() { : > "$run/stop"; command mkdir "$@"; }
    # shellcheck disable=SC2329 # Invoked by name through the queue callback.
    visit() { printf '%s\n' "$*" >> "$run/visited"; }
    lifecycle_run_queue "$run" visit </dev/null
)
[[ -d "$run/claims/raced" && ! -e "$run/visited" && ! -e "$run/done/raced" ]]
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
mkdir -p "$tree/scripts/lib"
cp "$ROOT/scripts/lib/"{process-pool,worker-resources}.sh "$tree/scripts/lib/"
cp "$ROOT/tests/integration/lifecycle-state.sh" "$tree/tests/integration/"
cp "$ROOT/tests/lib/"{logging,resource-ledger,lifecycle-matrix,lifecycle-jobs,lifecycle-contracts,lifecycle-assertions,fixture-ports}.sh "$tree/tests/lib/"
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
mkdir -p "$tree/src/host/core/project"
cp "$ROOT/src/host/core/project/hash.sh" "$tree/src/host/core/project/"
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
printf 'mkdir /fixture/state\n' > "$tree/mock-fault.trace"
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
# Locate new artifacts in the fixture tree, independently of display formatting.
declare -A known_runs=()
new_coordinator_run() {
    local candidate
    local -a created=()
    for candidate in "$tree"/testlog/*/matrix/lifecycle; do
        [[ ! -d "$candidate" || -n ${known_runs[$candidate]+x} ]] || created+=("$candidate")
    done
    [[ ${#created[@]} = 1 ]] || return 1
    run=${created[0]}
    known_runs[$run]=1
}
# Derive the expected cases before running the coordinator so a worker that
# omits both a fault and its manifest entry still fails this comparison.
{
    lifecycle_fixed_cases
    while IFS='|' read -r _ _ command scenario piece pieces; do
        lifecycle_fault_cases "$tree/mock-fault.trace" "$command" "$scenario" "${piece:-1}" "${pieces:-1}"
    done < "$TEST_ROOT/expected-fault-jobs"
} | LC_ALL=C sort > "$TEST_ROOT/expected-full-cases"
[[ -z $(uniq -d "$TEST_ROOT/expected-full-cases") ]]
for workers in 1 2 4; do
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS="$workers" JAILBOX_LIFECYCLE_TIMINGS=/dev/null \
        bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    grep -Fq 'matrix passed; logs: ' "$tree/output"
    new_coordinator_run
    cmp "$TEST_ROOT/expected-full-cases" "$run/completed-cases"
    cmp "$TEST_ROOT/job-ids" "$run/completed-jobs"
    grep -Fxq "workers=$workers" "$run/run-summary"
    grep -Eq '^elapsed_seconds=[0-9]+$' "$run/run-summary"
    grep -Fxq 'exit_status=0' "$run/run-summary"
    for file in "$run"/worker-*/fixture; do
        IFS= read -r fixture < "$file"
        [[ ! -e "$fixture" ]]
    done
    [[ $(find "$tree/ledger" -name '*.ledger' | wc -l) = 0 ]]
done
pass

TEST_CASE='workers avoid subnets already used on the host'
# shellcheck source=src/host/core/project/hash.sh
source "$ROOT/src/host/core/project/hash.sh"
occupied=$(seq 1 120 | tr '\n' ' ')
if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" JAILBOX_LIFECYCLE_JOBS=4 \
    JAILBOX_LIFECYCLE_TIMINGS=/dev/null POOL_TEST_HOST_OCTETS="$occupied" \
    bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
    cat "$tree/output" >&2; exit 1
fi
new_coordinator_run
for file in "$run"/worker-*/fixture; do
    IFS= read -r fixture < "$file"
    offset=$(jailbox_project_hash_port_offset "$(jailbox_project_hash_for_path "$fixture/project")")
    # First and fallback octets are 1 + subnet and 1 + (subnet + 7), both above 120.
    (( 1 + offset % 200 > 120 && 1 + (offset % 200 + 7) % 200 > 120 ))
done
if PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" JAILBOX_LIFECYCLE_JOBS=1 \
    POOL_TEST_HOST_OCTETS="$(seq 1 200 | tr '\n' ' ')" \
    bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
    echo 'FAIL: workers were allocated with every subnet occupied' >&2; exit 1
fi
grep -Fq 'could not allocate distinct worker identities with free subnets' "$tree/output"
new_coordinator_run
pass

TEST_CASE='coordinator shards together complete the full matrix'
: > "$TEST_ROOT/shard-cases"
for shard in 1/2 2/2; do
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS=2 JAILBOX_LIFECYCLE_SHARD="$shard" \
        bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    grep -Fq "matrix shard $shard passed (partial coverage); logs: " "$tree/output"
    new_coordinator_run
    grep -Fxq "shard=$shard" "$run/run-summary"
    cat "$run/completed-cases" >> "$TEST_ROOT/shard-cases"
    # Lay the run out as CI downloads it: one directory per shard artifact.
    mkdir -p "$TEST_ROOT/shard-logs/matrix-logs-${shard%/*}/stamp/matrix"
    cp -R "$run" "$TEST_ROOT/shard-logs/matrix-logs-${shard%/*}/stamp/matrix/lifecycle"
done
LC_ALL=C sort "$TEST_ROOT/shard-cases" > "$TEST_ROOT/actual"
cmp "$TEST_ROOT/expected-full-cases" "$TEST_ROOT/actual"
logs="$TEST_ROOT/shard-logs"
bash "$ROOT/tests/ci/check-matrix-pieces.sh" 2 "$logs" > "$TEST_ROOT/pieces-output"
grep -Fq 'recorded the same operations across 2 shards' "$TEST_ROOT/pieces-output"
grep -c '^fault\.[^|]*\.p[1-9]|' "$logs"/matrix-logs-*/stamp/matrix/lifecycle/catalog |
    awk -F: '$2 > 0 { shards++ } END { exit shards == 2 ? 0 : 1 }'
# Every shard's passing run is required exactly once, and pieces must match.
check_shard_logs() {
    local expected="$1"
    if bash "$ROOT/tests/ci/check-matrix-pieces.sh" 2 "$logs" > "$TEST_ROOT/pieces-output" 2>&1; then
        echo "FAIL: matrix pieces accepted without: $expected" >&2; exit 1
    fi
    grep -Fq "$expected" "$TEST_ROOT/pieces-output"
}
mv "$logs/matrix-logs-2" "$TEST_ROOT/held-shard"
check_shard_logs 'shard 2/2 has no run'
cp -R "$logs/matrix-logs-1" "$logs/matrix-logs-2"
check_shard_logs 'shard 1/2 has more than one run'
rm -r -- "$logs/matrix-logs-2"
mv "$TEST_ROOT/held-shard" "$logs/matrix-logs-2"
summary="$logs/matrix-logs-2/stamp/matrix/lifecycle/run-summary"
sed -i.bak 's/^exit_status=0$/exit_status=1/' "$summary"
check_shard_logs 'shard 2/2 did not pass'
mv "$summary.bak" "$summary"
if bash "$ROOT/tests/ci/check-matrix-pieces.sh" 3 "$logs" > "$TEST_ROOT/pieces-output" 2>&1; then
    echo 'FAIL: matrix pieces accepted for the wrong shard count' >&2; exit 1
fi
grep -Fq 'is not a run of one of 3 shards' "$TEST_ROOT/pieces-output"
for events in "$logs"/matrix-logs-2/stamp/matrix/lifecycle/worker-*/trace.*.p[1-9]/events; do
    printf 'extra operation\n' >> "$events"
    break
done
if bash "$ROOT/tests/ci/check-matrix-pieces.sh" 2 "$logs" > "$TEST_ROOT/pieces-output" 2>&1; then
    echo 'FAIL: mismatched pieces across shards accepted' >&2; exit 1
fi
grep -Fq 'recorded different operations' "$TEST_ROOT/pieces-output"
for shard in 0/2 3/2 1/0 1/100 x 1/2/3; do
    if PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" JAILBOX_LIFECYCLE_SHARD="$shard" \
        bash "$tree/tests/integration/lifecycle-state.sh" > "$tree/output" 2>&1; then
        echo "FAIL: invalid shard $shard accepted" >&2; exit 1
    fi
    grep -Fq 'JAILBOX_LIFECYCLE_SHARD must be INDEX/COUNT' "$tree/output"
done
if PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" JAILBOX_LIFECYCLE_SHARD=1/2 \
    bash "$tree/tests/integration/lifecycle-state.sh" --sample-50 > "$tree/output" 2>&1; then
    echo 'FAIL: sharded sample accepted' >&2; exit 1
fi
grep -Fq 'lifecycle samples cannot be sharded' "$tree/output"
pass

TEST_CASE='sample coordinator verifies 50 and 150 cases and cleans up'
for sample_run in 50:1 50:4 50:8 150:1 150:4 150:8; do
    size=${sample_run%:*}
    workers=${sample_run#*:}
    jobs=17
    cp "$TEST_ROOT/expected-sample" "$TEST_ROOT/current-sample"
    if [[ "$size" = 150 ]]; then
        jobs=49
        cp "$TEST_ROOT/benchmark-rows" "$TEST_ROOT/current-sample"
        grep '^home-inspection\.' "$TEST_ROOT/all-fixed" >> "$TEST_ROOT/current-sample"
    fi
    if ! PATH="$tree/bin:$PATH" JAILBOX_TEST_LEDGER_DIR="$tree/ledger" \
        JAILBOX_LIFECYCLE_JOBS="$workers" JAILBOX_LIFECYCLE_TIMINGS=/missing-history \
        bash "$tree/tests/integration/lifecycle-state.sh" "--sample-$size" > "$tree/output" 2>&1; then
        cat "$tree/output" >&2; exit 1
    fi
    grep -Fq 'sample passed (partial coverage); logs: ' "$tree/output"
    new_coordinator_run
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

TEST_CASE='coordinator failures and cancellation preserve cleanup ownership'
python3 "$ROOT/tests/lib/check-lifecycle-cancellation.py" "$tree"
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

TEST_CASE='the real worker loads the catalog needed by row recovery contracts'
cp "$ROOT/tests/lib/"{lifecycle-worker,lifecycle-assertions,lifecycle-fixture,lifecycle-runtime,lifecycle-runtime-faults,lifecycle-logging}.sh "$tree/tests/lib/"
cat "$ROOT/tests/fixtures/lifecycle-pool/worker-bootstrap.sh" >> "$tree/tests/lib/lifecycle-runtime-faults.sh"
for variant in complete missing-catalog; do
    run="$tree/bootstrap-$variant"
    mkdir -p "$run/claims" "$run/done" "$run/log"
    printf 'absent.up\n' > "$run/expected-fixed"
    printf 'row.running|row|running|plain|false|false|success|running|allow|none|keep|stopped\n' > "$run/jobs"
    if [[ "$variant" = missing-catalog ]]; then
        sed '/^source .*\/lifecycle-matrix.sh"$/d' "$ROOT/tests/lib/lifecycle-worker.sh" > "$tree/tests/lib/lifecycle-worker.sh"
    fi
    result=0
    JAILBOX_TEST_PROGRESS_TERMINAL=true bash "$tree/tests/lib/lifecycle-worker.sh" "$run" "$run/log" "$run/fixture" > "$run/output" 2>&1 || result=$?
    if [[ "$variant" = complete ]]; then
        [[ "$result" = 0 ]] || { cat "$run/output"; exit 1; }
        [[ -f "$run/done/row.running" ]]
    else
        [[ "$result" != 0 && ! -e "$run/done/row.running" ]]
        grep -Fq 'lifecycle_matrix_rows: command not found' "$run/log/worker.log"
        grep -Fq 'invalid recovery contracts' "$run/log/worker.log"
    fi
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
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = "6|$((10 * 1048576))" ]]
[[ $(worker_linux_resources "$proc" "$cgroup" 2) = "2|$((10 * 1048576))" ]]
printf '150000 100000\n' > "$cgroup/cpu.max"
printf '%s\n' "$((8 * 1073741824))" > "$cgroup/memory.max"
printf '%s\n' "$((4 * 1073741824))" > "$cgroup/memory.current"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = "1|$((4 * 1048576))" ]]
printf 'MemAvailable: 1048576 kB\n' > "$proc/meminfo"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|1048576' ]]
pass

TEST_CASE='unknown resource data and exhausted cgroups select one worker'
printf 'unknown\n' > "$proc/meminfo"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf 'MemAvailable: 67108864 kB\n' > "$proc/meminfo"
printf '%s\n' "$((9 * 1073741824))" > "$cgroup/memory.current"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf 'garbage\n' > "$cgroup/memory.max"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf '0::/../../outside\n' > "$proc/self/cgroup"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|0' ]]
printf '2:memory:/legacy\n' > "$proc/self/cgroup"
[[ $(worker_linux_resources "$proc" "$cgroup" 16) = '1|0' ]]
pass
