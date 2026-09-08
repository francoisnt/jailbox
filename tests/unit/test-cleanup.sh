#!/bin/bash
# The e2e fixtures' resource ledger: what it records, what it removes, what it
# refuses to touch, and how it recovers a run that was interrupted.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/config-digest.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/tests/lib/resource-ledger.sh"

FIXTURE=$(mktemp -d)
FIXTURE=$(cd "$FIXTURE" && pwd -P)
PROJECT_DIRS=()
cleanup_fixture() {
    local dir
    rm -rf "$FIXTURE"
    for dir in "${PROJECT_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup_fixture EXIT

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

# ── fake Podman ───────────────────────────────────────────────────────────────
#
# A directory of files named <kind>.<name>. FAKE_PODMAN_UNREMOVABLE lists
# kind.name entries whose removal silently does nothing, standing in for a
# failed or interrupted cleanup. FAKE_PODMAN_PROBE_ERROR names a kind whose
# existence probe errors, standing in for a Podman that cannot answer.
# FAKE_PODMAN_REMOVE_DELAY slows every removal, widening the window two
# concurrent sweeps have to collide in.

mkdir -p "$FIXTURE/bin"
cat > "$FIXTURE/bin/podman" <<'EOF_PODMAN'
#!/bin/sh
state="$FAKE_PODMAN_STATE"

probe() {
    [ "${FAKE_PODMAN_PROBE_ERROR:-}" != "$1" ] || exit 125
    [ -f "$state/$1.$2" ]
}

remove() {
    [ -z "${FAKE_PODMAN_REMOVE_DELAY:-}" ] || sleep "$FAKE_PODMAN_REMOVE_DELAY"
    case " ${FAKE_PODMAN_UNREMOVABLE:-} " in
        *" $1.$2 "*) exit 0 ;;
    esac
    [ -f "$state/$1.$2" ] || exit 1
    printf '%s %s\n' "$1" "$2" >> "$state/removed"
    rm -f "$state/$1.$2"
}

case "$1 $2" in
    "container exists") probe container "$3" ;;
    "volume exists")    probe volume "$3" ;;
    "network exists")   probe network "$3" ;;
    "image exists")     probe image "$3" ;;
    "volume rm")        remove volume "$4" ;;
    "network rm")       remove network "$4" ;;
    *)
        case "$1" in
            rm)  remove container "$3" ;;
            rmi) remove image "$3" ;;
            *) exit 1 ;;
        esac
        ;;
esac
EOF_PODMAN
chmod +x "$FIXTURE/bin/podman"
PATH="$FIXTURE/bin:$PATH"
export FAKE_PODMAN_STATE="$FIXTURE/podman-state"
mkdir -p "$FAKE_PODMAN_STATE"

export JAILBOX_TEST_LEDGER_DIR="$FIXTURE/ledger"

reset_state() {
    rm -rf "$FAKE_PODMAN_STATE" "$JAILBOX_TEST_LEDGER_DIR"
    mkdir -p "$FAKE_PODMAN_STATE"
    unset FAKE_PODMAN_UNREMOVABLE FAKE_PODMAN_PROBE_ERROR FAKE_PODMAN_REMOVE_DELAY
    LEDGER_DIR=""
    LEDGER_FILE=""
}

put_resource() { : > "$FAKE_PODMAN_STATE/$1.$2"; }
resource_present() { [ -f "$FAKE_PODMAN_STATE/$1.$2" ]; }

# A fixture project directory of the shape the ledger accepts, plus the
# resource prefix jailbox derives from it. Sets `project` and `prefix` for the
# caller and registers the directory for removal at exit, so it must not run in
# a subshell — a command substitution would discard both. Several cases delete
# their directory early on purpose.
new_fixture_project() {
    project=$(mktemp -d "/tmp/jailbox-${1:-e2e}-unit.XXXXXX")
    PROJECT_DIRS+=("$project")
    prefix=$(jailbox_resource_prefix_for_path "$project")
}

# Every resource the ledger records for a project, materialized in fake Podman.
create_recorded_resources() {
    local kind name
    while read -r kind name; do
        put_resource "$kind" "$name"
    done < <(ledger_entries "$LEDGER_FILE")
}

ledger_line_count() {
    ledger_entries "$LEDGER_FILE" | wc -l | tr -d ' '
}

# ── the recorded inventory ────────────────────────────────────────────────────

echo "── recorded inventory ──"

reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"

recorded=$(ledger_entries "$LEDGER_FILE")
missing=""
# The ledger must cover everything a launch of this project can leave behind:
# every digest-inventory member, the home volume outside it, and the images
# `jailbox --clean` never removes.
PROJECT_DIR="$project"
initialize_project_names
while IFS= read -r target; do
    case "$recorded" in
        *"${target%%:*} ${target#*:}"*) ;;
        *) missing="${missing:+$missing, }$target" ;;
    esac
done < <(config_digest_inventory; printf 'volume:%s\n' "$VOLUME_NAME")
if [ -z "$missing" ]; then
    pass "the ledger covers every resource a launch of the fixture can create"
else
    fail "the ledger covers every resource a launch of the fixture can create (missing: $missing)"
fi

for image in "$prefix-image" "$prefix-dev" "$prefix-proxy"; do
    case "$recorded" in
        *"image $image"*) pass "the ledger records the $image image" ;;
        *) fail "the ledger records the $image image" ;;
    esac
done

# The proxy container and the proxy image are one name under two kinds.
if [ "$(printf '%s\n' "$recorded" | grep -c -- "-proxy$")" -eq 2 ]; then
    pass "the shared proxy name is recorded once per kind"
else
    fail "the shared proxy name is recorded once per kind"
fi

if ledger_record_project_resources "$FIXTURE/not-a-fixture" 2>/dev/null; then
    fail "recording refuses a project outside the fixture paths"
else
    pass "recording refuses a project outside the fixture paths"
fi
if ledger_record pod "$prefix" 2>/dev/null; then
    fail "recording refuses an unknown resource kind"
else
    pass "recording refuses an unknown resource kind"
fi
if ledger_record container "name with a space" 2>/dev/null; then
    fail "recording refuses a name that would not round-trip"
else
    pass "recording refuses a name that would not round-trip"
fi
if ledger_record container "" 2>/dev/null; then
    fail "recording refuses an empty name"
else
    pass "recording refuses an empty name"
fi

# ── removal scope ─────────────────────────────────────────────────────────────

echo "── removal scope ──"

reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"
create_recorded_resources

# Never recorded: the shared stage build caches, a real project's live sandbox
# — the one this suite may itself be running inside — and debris from a run
# that predates the ledger.
put_resource image jailbox-wrapper-debian
put_resource image jailbox-test-debian
put_resource container jailbox-myrepo-0123456789ab
put_resource volume jailbox-myrepo-0123456789ab-home
put_resource container jailbox-editor-legacy-aabbccddeeff
put_resource network jailbox-editor-legacy-aabbccddeeff-net

ledger_sweep_own_run >/dev/null

if ! resource_present container "$prefix" && ! resource_present container "$prefix-proxy" &&
    ! resource_present volume "$prefix-home" && ! resource_present network "$prefix-net" &&
    ! resource_present network "$prefix-net-internal" && ! resource_present network "$prefix-net-external"; then
    pass "the sweep removes every recorded container, volume, and network"
else
    fail "the sweep removes every recorded container, volume, and network"
fi
if ! resource_present image "$prefix-proxy" && ! resource_present image "$prefix-image" &&
    ! resource_present image "$prefix-dev"; then
    pass "the sweep removes every recorded image"
else
    fail "the sweep removes every recorded image"
fi
if resource_present image jailbox-wrapper-debian && resource_present image jailbox-test-debian; then
    pass "the sweep preserves the shared stage build caches"
else
    fail "the sweep preserves the shared stage build caches"
fi
if resource_present container jailbox-myrepo-0123456789ab &&
    resource_present volume jailbox-myrepo-0123456789ab-home; then
    pass "the sweep preserves a real project's sandbox"
else
    fail "the sweep preserves a real project's sandbox"
fi
if resource_present container jailbox-editor-legacy-aabbccddeeff &&
    resource_present network jailbox-editor-legacy-aabbccddeeff-net; then
    pass "the sweep preserves unrecorded debris from runs predating the ledger"
else
    fail "the sweep preserves unrecorded debris from runs predating the ledger"
fi
if [ ! -f "$LEDGER_FILE" ]; then
    pass "a fully swept ledger is deleted"
else
    fail "a fully swept ledger is deleted"
fi

# The proxy container and image share a name; each is removed on its own.
reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"
put_resource image "$prefix-proxy"
ledger_sweep_own_run >/dev/null
if ! resource_present image "$prefix-proxy"; then
    pass "an image is removed under the proxy name with no container of that name"
else
    fail "an image is removed under the proxy name with no container of that name"
fi

reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"
put_resource container "$prefix-proxy"
put_resource image "$prefix-proxy"
ledger_sweep_own_run >/dev/null
if ! resource_present container "$prefix-proxy" && ! resource_present image "$prefix-proxy"; then
    pass "a container and an image sharing the proxy name are both removed"
else
    fail "a container and an image sharing the proxy name are both removed"
fi

# ── retries after a failed or interrupted cleanup ─────────────────────────────

echo "── retries ──"

reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"
create_recorded_resources

export FAKE_PODMAN_UNREMOVABLE="container.$prefix volume.$prefix-home"
ledger_sweep_own_run >/dev/null 2>&1
if resource_present container "$prefix" && resource_present volume "$prefix-home"; then
    pass "a removal that silently fails leaves the resource in place"
else
    fail "a removal that silently fails leaves the resource in place"
fi
if [ -f "$LEDGER_FILE" ] && [ "$(ledger_line_count)" -eq 2 ]; then
    pass "the ledger keeps exactly the entries whose resources are still present"
else
    fail "the ledger keeps exactly the entries whose resources are still present (kept: $(ledger_line_count))"
fi

# The fixture directory is gone by the time the retry runs; the ledger outside
# it is the only thing that still knows these names.
rm -rf "$project"
unset FAKE_PODMAN_UNREMOVABLE
ledger_sweep_own_run >/dev/null
if ! resource_present container "$prefix" && ! resource_present volume "$prefix-home" &&
    [ ! -f "$LEDGER_FILE" ]; then
    pass "a retry without the fixture directory completes the cleanup"
else
    fail "a retry without the fixture directory completes the cleanup"
fi

# An existence probe that errors is not proof of absence, so the entry stays.
reset_state
new_fixture_project e2e
ledger_begin_run unit
ledger_record_project_resources "$project"
export FAKE_PODMAN_PROBE_ERROR=network
ledger_sweep_own_run >/dev/null 2>&1
if [ -f "$LEDGER_FILE" ] && [ "$(ledger_line_count)" -eq 3 ]; then
    pass "entries whose existence cannot be determined are kept"
else
    fail "entries whose existence cannot be determined are kept (kept: $(ledger_line_count))"
fi
unset FAKE_PODMAN_PROBE_ERROR

# ── liveness of other runs ────────────────────────────────────────────────────

echo "── other runs ──"

# Write another run's ledger with a chosen header, plus its resources.
other_run_ledger() {
    local name="$1" header="$2" kind resource
    shift 2

    mkdir -p "$JAILBOX_TEST_LEDGER_DIR"
    printf '%s\n' "$header" > "$JAILBOX_TEST_LEDGER_DIR/$name.ledger"
    for resource in "$@"; do
        kind="${resource%%.*}"
        printf '%s %s\n' "$kind" "${resource#*.}" >> "$JAILBOX_TEST_LEDGER_DIR/$name.ledger"
        put_resource "$kind" "${resource#*.}"
    done
}

# Append owner lines to another run's ledger.
other_run_owner() {
    printf 'owner %s %s\n' "$2" "$3" >> "$JAILBOX_TEST_LEDGER_DIR/$1.ledger"
}

# This host's own liveness sources, before anything is mocked. procfs (Linux)
# and ps (macOS) are both optional, and so is the boot id; where a host answers
# with neither, the library must report uncertainty rather than guess, which is
# what the mocked FAKE_START_MECHANISM=0 case below proves. Whatever a host
# does answer has to be a single whitespace-free ledger field.
own_start=$(ledger_process_start "$$") || own_start=""
own_boot=$(ledger_boot_id)

case "$own_start" in
    *[[:space:]]*) fail "a real start time is a single ledger field" ;;
    *) pass "a real start time is a single ledger field" ;;
esac
case "$own_boot" in
    *[[:space:]]*) fail "a real boot id is a single ledger field" ;;
    *) pass "a real boot id is a single ledger field" ;;
esac

if [ -n "$own_start" ] && [ -n "$own_boot" ]; then
    if [ "$(ledger_run_state "$$" "$own_start" "$own_boot")" = active ]; then
        pass "this host's real liveness sources recognize a live owner"
    else
        fail "this host's real liveness sources recognize a live owner"
    fi
else
    echo "  ⏭️  this host reports no process start time or boot id; only the mocked cases run"
fi

# ── liveness decisions ────────────────────────────────────────────────────────
#
# The remaining cases mock both liveness sources, so the decision logic is
# exercised identically on a host with procfs, one with only ps, and one with
# neither. FAKE_PROCESSES maps a live pid to its start token; a pid absent from
# it no longer exists. FAKE_START_MECHANISM=0 stands in for a host that can
# report no start time at all, where nothing may be declared ended.

echo "── liveness decisions ──"

declare -A FAKE_PROCESSES=()
FAKE_BOOT_ID="boot-current"
FAKE_START_MECHANISM=1

ledger_boot_id() { printf '%s' "$FAKE_BOOT_ID"; }
ledger_process_start() {
    [ "$FAKE_START_MECHANISM" = 1 ] || return 1
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    [[ -v FAKE_PROCESSES[$1] ]] || return 1
    printf '%s' "${FAKE_PROCESSES[$1]}"
}

# The runner of every mocked case, alive unless a case says otherwise.
RUNNER_PID=4001
WORKER_PID=4002
reset_processes() {
    # This suite's own pid is live too: ledger_run_state probes it to tell a
    # host that cannot read start times from one where the owner really ended.
    FAKE_PROCESSES=([$$]=start-self [$RUNNER_PID]=start-runner [$WORKER_PID]=start-worker)
    FAKE_START_MECHANISM=1
    FAKE_BOOT_ID="boot-current"
}
reset_processes

boot="$FAKE_BOOT_ID"

# One case: set up another run's ledger, prune, and report whether its resource
# and ledger survived.
assert_prune() {
    local description="$1" expectation="$2" header="$3"
    shift 3
    local survived=0 owner

    reset_state
    reset_processes
    ledger_begin_run unit
    other_run_ledger other "$header" container.jailbox-e2e-other-999999999999
    # Each remaining argument is one worker as "<pid> <start>".
    for owner in "$@"; do
        other_run_owner other "${owner%% *}" "${owner#* }"
    done
    ledger_prune_stale_runs >/dev/null

    if resource_present container jailbox-e2e-other-999999999999 &&
        [ -f "$JAILBOX_TEST_LEDGER_DIR/other.ledger" ]; then
        survived=1
    fi
    if [ "$expectation" = preserved ] && [ "$survived" -eq 1 ]; then
        pass "$description"
    elif [ "$expectation" = pruned ] && [ "$survived" -eq 0 ]; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_prune "a run whose owning process is gone is pruned" \
    pruned "run 4999 start-gone $boot"
assert_prune "a live runner keeps its run" \
    preserved "run $RUNNER_PID start-runner $boot"
assert_prune "a recycled pid does not make a finished run look active" \
    pruned "run $RUNNER_PID start-before-reuse $boot"
assert_prune "a run recorded before a reboot is pruned" \
    pruned "run $RUNNER_PID start-runner boot-previous"
assert_prune "a run recorded without a start time is preserved" \
    preserved "run $RUNNER_PID unknown $boot"
assert_prune "a run recorded without a boot id is preserved" \
    preserved "run 4999 start-gone unknown"
assert_prune "a run with a malformed header is preserved" \
    preserved "run  start-gone $boot"

# A killed runner orphans its background workers rather than stopping them, so
# a surviving worker must keep the whole run — and every resource it is still
# using — off the removal list.
assert_prune "a dead runner with a surviving worker is preserved" \
    preserved "run 4999 start-gone $boot" "$WORKER_PID start-worker"
assert_prune "a dead runner is pruned once every worker has ended too" \
    pruned "run 4999 start-gone $boot" "4998 start-gone-worker"
assert_prune "one surviving worker among several ended ones preserves the run" \
    preserved "run 4999 start-gone $boot" "4998 start-gone-worker" "$WORKER_PID start-worker"
assert_prune "a worker whose start time cannot be read preserves the run" \
    preserved "run 4999 start-gone $boot" "$WORKER_PID unknown"

# Both gates share one implementation and differ only in their tag, so each is
# proved against a live owner.
for tag in editor e2e; do
    reset_state
    reset_processes
    ledger_begin_run unit
    other_run_ledger "$tag-active" "run $RUNNER_PID start-runner $boot" \
        "container.jailbox-$tag-live-222222222222" \
        "volume.jailbox-$tag-live-222222222222-home" \
        "image.jailbox-$tag-live-222222222222-image"
    ledger_prune_stale_runs >/dev/null
    if resource_present container "jailbox-$tag-live-222222222222" &&
        resource_present volume "jailbox-$tag-live-222222222222-home" &&
        resource_present image "jailbox-$tag-live-222222222222-image" &&
        [ -f "$JAILBOX_TEST_LEDGER_DIR/$tag-active.ledger" ]; then
        pass "an active $tag run's resources and ledger are preserved"
    else
        fail "an active $tag run's resources and ledger are preserved"
    fi
done

# A host that can report no process start time at all — no procfs and no
# usable ps — must never conclude that a run has ended.
reset_state
reset_processes
FAKE_START_MECHANISM=0
ledger_begin_run unit
other_run_ledger nomechanism "run 4999 start-gone $boot" \
    container.jailbox-e2e-nomechanism-666666666666
ledger_prune_stale_runs >/dev/null
if resource_present container jailbox-e2e-nomechanism-666666666666 &&
    [ -f "$JAILBOX_TEST_LEDGER_DIR/nomechanism.ledger" ]; then
    pass "a host that cannot read start times prunes nothing"
else
    fail "a host that cannot read start times prunes nothing"
fi
reset_processes

# Owner lines are bookkeeping, never removal targets.
reset_state
reset_processes
ledger_begin_run unit
ledger_record_owner "$WORKER_PID"
ledger_record container jailbox-e2e-owner-777777777777
put_resource container jailbox-e2e-owner-777777777777
if [ "$(ledger_line_count)" -eq 1 ]; then
    pass "an owner line is not read back as a resource"
else
    fail "an owner line is not read back as a resource (entries: $(ledger_line_count))"
fi
if ! ledger_record_owner "not-a-pid" 2>/dev/null; then
    pass "recording refuses an owner that is not a pid"
else
    fail "recording refuses an owner that is not a pid"
fi

# ── interrupted cache seeding ─────────────────────────────────────────────────

echo "── interrupted cache seeding ──"

# The editor fixture records the seed helper's volume and container before
# creating either. A run killed mid-seed leaves them behind and loses its
# fixture directory; the next run must still find and remove them.
reset_state
reset_processes
new_fixture_project editor
ledger_begin_run unit
ledger_record_project_resources "$project"
ledger_record volume "$prefix-home"
ledger_record container "$prefix-seed"
put_resource volume "$prefix-home"
put_resource container "$prefix-seed"

# Kill the run: its ledger keeps every recorded name, its header names a
# process that no longer exists, and its fixture directory is gone.
interrupted="$JAILBOX_TEST_LEDGER_DIR/interrupted.ledger"
{ printf 'run 4999 start-gone %s\n' "$boot"; tail -n +2 "$LEDGER_FILE"; } > "$interrupted"
rm -f "$LEDGER_FILE"
rm -rf "$project"

ledger_begin_run unit
ledger_prune_stale_runs >/dev/null
if ! resource_present volume "$prefix-home" && ! resource_present container "$prefix-seed"; then
    pass "a run interrupted during cache seeding is recovered without its fixture directory"
else
    fail "a run interrupted during cache seeding is recovered without its fixture directory"
fi
if [ ! -f "$interrupted" ]; then
    pass "the interrupted run's ledger is retired once its resources are gone"
else
    fail "the interrupted run's ledger is retired once its resources are gone"
fi

echo "── worker registration barrier ──"

reset_state
ledger_begin_run unit
worker_checks_registration() {
    grep -q "^owner $BASHPID " "$LEDGER_FILE" &&
        touch "$FIXTURE/worker-ran"
}
# Never let a failure here reach `set -e`: a regression makes the worker exit
# non-zero, or makes it fail to start at all, and that has to surface as a
# failed assertion rather than as a suite that dies without reporting anything.
if ledger_start_worker worker_checks_registration; then
    wait "$LEDGER_WORKER_PID" || true
else
    fail "the registration case starts a worker"
fi
if [ -f "$FIXTURE/worker-ran" ]; then
    pass "a worker observes its own registration before doing work"
else
    fail "a worker observes its own registration before doing work"
fi
rm -f "$FIXTURE/worker-ran"

# End the forking shell inside registration, before it can release the child.
# A private, known barrier lets the test wait for the orphan to exit without
# relying on a fixed sleep or a process that is not this shell's child. The
# child removes the barrier on its way out and leaves a marker, so its exit is
# positive evidence that it ran and bailed — not merely that it never started.
interrupted_worker() {
    touch "$FIXTURE/worker-ran"
}
(
    mktemp() { mkdir "$FIXTURE/interrupted-barrier" && printf '%s\n' "$FIXTURE/interrupted-barrier"; }
    ledger_record_owner() { touch "$FIXTURE/registration-reached"; exit 0; }
    ledger_start_worker interrupted_worker
) || true
for ((attempt = 0; attempt < 100; attempt++)); do
    [ -d "$FIXTURE/interrupted-barrier" ] || break
    sleep 0.05
done
if [ ! -f "$FIXTURE/registration-reached" ]; then
    fail "the interrupted-registration case actually forks a worker"
elif [ -d "$FIXTURE/interrupted-barrier" ]; then
    fail "an interrupted registration exits the worker without starting work (the worker never exited)"
elif [ -f "$FIXTURE/worker-ran" ]; then
    fail "an interrupted registration exits the worker without starting work (the worker ran anyway)"
else
    pass "an interrupted registration exits the worker without starting work"
fi
rm -f "$FIXTURE/registration-reached"

# The runner dies during registration and its pid is immediately reused, so the
# liveness check keeps saying the runner is alive while `ready` never arrives.
# Without a bounded wait the worker would spin at tick rate forever, holding
# every descriptor it inherited.
(
    mktemp() { mkdir "$FIXTURE/timeout-barrier" && printf '%s\n' "$FIXTURE/timeout-barrier"; }
    kill() { return 0; }                 # the runner's pid looks alive forever
    ledger_record_owner() { exit 0; }    # the runner dies without releasing it
    LEDGER_REGISTRATION_TIMEOUT_TICKS=2
    LEDGER_REGISTRATION_TICK=0.05
    ledger_start_worker interrupted_worker
) || true
for ((attempt = 0; attempt < 100; attempt++)); do
    [ -d "$FIXTURE/timeout-barrier" ] || break
    sleep 0.05
done
if [ ! -d "$FIXTURE/timeout-barrier" ] && [ ! -f "$FIXTURE/worker-ran" ]; then
    pass "a worker gives up when registration never completes"
else
    fail "a worker gives up when registration never completes"
fi
rm -f "$FIXTURE/worker-ran"

# ── concurrent pruning ────────────────────────────────────────────────────────
#
# Both gates share the ledger directory, so two runs can decide the same stale
# run has ended and sweep it at the same moment. Neither may fail: cleanup runs
# under `set -e` in both gates, so a losing writer would abort a whole gate.

echo "── concurrent pruning ──"

# A resource that never goes away forces the rewrite path, which is where the
# two sweeps collide. The removal also stalls, widening the window.
stale_ledger_with_stuck_resource() {
    reset_state
    reset_processes
    mkdir -p "$JAILBOX_TEST_LEDGER_DIR"
    printf 'run 4999 start-gone %s\ncontainer jailbox-e2e-stuck-888888888888\n' "$boot" \
        > "$JAILBOX_TEST_LEDGER_DIR/stale.ledger"
    put_resource container jailbox-e2e-stuck-888888888888
    export FAKE_PODMAN_UNREMOVABLE="container.jailbox-e2e-stuck-888888888888"
    export FAKE_PODMAN_REMOVE_DELAY=0.2
    LEDGER_DIR="$JAILBOX_TEST_LEDGER_DIR"
}

stale_ledger_with_stuck_resource
prune_in_background() {
    (
        LEDGER_FILE="$JAILBOX_TEST_LEDGER_DIR/own-$1.ledger"
        ledger_prune_stale_runs
    ) >"$FIXTURE/prune-$1.out" 2>&1 &
}
prune_in_background a
first=$!
prune_in_background b
second=$!
first_status=0
second_status=0
wait "$first" || first_status=$?
wait "$second" || second_status=$?

if [ "$first_status" -eq 0 ] && [ "$second_status" -eq 0 ]; then
    pass "concurrent sweeps of one stale ledger both succeed"
else
    fail "concurrent sweeps of one stale ledger both succeed (exits $first_status and $second_status)"
    sed 's/^/     /' "$FIXTURE/prune-a.out" "$FIXTURE/prune-b.out" 2>/dev/null || true
fi
if ! grep -qs "cannot stat\|^mv:" "$FIXTURE/prune-a.out" "$FIXTURE/prune-b.out"; then
    pass "neither sweep loses a rename to the other"
else
    fail "neither sweep loses a rename to the other"
fi
# The surviving ledger must still be usable: a run header, and the retained
# entry exactly once.
if [ "$(head -n 1 "$JAILBOX_TEST_LEDGER_DIR/stale.ledger" | cut -d' ' -f1)" = run ] &&
    [ "$(ledger_entries "$JAILBOX_TEST_LEDGER_DIR/stale.ledger" | wc -l | tr -d ' ')" -eq 1 ]; then
    pass "the ledger survives a concurrent sweep intact"
else
    fail "the ledger survives a concurrent sweep intact"
    sed 's/^/     /' "$JAILBOX_TEST_LEDGER_DIR/stale.ledger" 2>/dev/null || true
fi
if [ -z "$(find "$JAILBOX_TEST_LEDGER_DIR" -name 'stale.ledger.*' -print 2>/dev/null)" ]; then
    pass "a concurrent sweep leaves no temporary or lock behind"
else
    fail "a concurrent sweep leaves no temporary or lock behind"
fi
unset FAKE_PODMAN_UNREMOVABLE FAKE_PODMAN_REMOVE_DELAY

# Exercise real processes and real kernel locks, independently of the mocked
# liveness sources above. In particular, no fabricated owner record can hide a
# mismatch between a shell's pid and a command substitution's start time.
for backend in flock perl; do
    if ! command -v "$backend" >/dev/null 2>&1; then
        echo "  ⏭️  $backend is unavailable; skipping its lock backend"
        continue
    fi
    stale_ledger_with_stuck_resource
    unset FAKE_PODMAN_UNREMOVABLE FAKE_PODMAN_REMOVE_DELAY
    mkfifo "$JAILBOX_TEST_LEDGER_DIR/hold"
    (
        # Force the portable backend even on a host with the flock command.
        # Invoked indirectly by the sourced lock helper.
        # shellcheck disable=SC2317,SC2329
        command() {
            if [[ "$backend" == perl && "$*" == '-v flock' ]]; then
                return 1
            fi
            builtin command "$@"
        }
        exec {hold_fd}<>"$JAILBOX_TEST_LEDGER_DIR/hold"
        exec {lock_fd}>>"$JAILBOX_TEST_LEDGER_DIR/.cleanup.lock"
        ledger_lock_descriptor "$lock_fd" || exit 1
        touch "$JAILBOX_TEST_LEDGER_DIR/holding"
        # A builtin wait leaves no descendant holding the descriptor when
        # this shell is killed. Bound it so a broken test cannot hang forever.
        read -r -t 10 -u "$hold_fd" _ || true
    ) &
    holder=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -f "$JAILBOX_TEST_LEDGER_DIR/holding" ]] && break
        sleep 0.01
    done
    if [[ ! -f "$JAILBOX_TEST_LEDGER_DIR/holding" ]]; then
        fail "$backend starts a real lock holder"
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true
        continue
    fi
    ledger_prune_stale_runs >/dev/null 2>&1
    if resource_present container jailbox-e2e-stuck-888888888888; then
        pass "$backend preserves a ledger locked by a live process"
    else
        fail "$backend preserves a ledger locked by a live process"
    fi

    kill -KILL "$holder"
    wait "$holder" 2>/dev/null || true
    # Two contenders now race after an interrupted cleanup. Holding the kernel
    # lock in the removal stub lets us detect overlap, not just successful exits.
    (
        # Invoked indirectly by the sourced sweep helper.
        # shellcheck disable=SC2317,SC2329
        ledger_remove_resource() {
            touch "$JAILBOX_TEST_LEDGER_DIR/sweep-attempted"
            if ! mkdir "$JAILBOX_TEST_LEDGER_DIR/in-sweep" 2>/dev/null; then
                touch "$JAILBOX_TEST_LEDGER_DIR/overlap"
                return 1
            fi
            sleep 0.1
            rmdir "$JAILBOX_TEST_LEDGER_DIR/in-sweep"
        }
        prune_in_background a
        first=$!
        prune_in_background b
        second=$!
        wait "$first" && wait "$second"
    ) || fail "$backend retries succeed after a killed holder"
    if [[ -f "$JAILBOX_TEST_LEDGER_DIR/sweep-attempted" &&
        ! -f "$JAILBOX_TEST_LEDGER_DIR/overlap" ]]; then
        pass "$backend serializes contenders after a killed holder"
    else
        fail "$backend serializes contenders after a killed holder"
    fi
    ledger_prune_stale_runs >/dev/null 2>&1
    if ! resource_present container jailbox-e2e-stuck-888888888888 &&
        [[ ! -f "$JAILBOX_TEST_LEDGER_DIR/stale.ledger" ]]; then
        pass "$backend releases an interrupted sweep without stale-lock reclamation"
    else
        fail "$backend releases an interrupted sweep without stale-lock reclamation"
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "test cleanup ledger: $PASSED passed"
else
    echo "test cleanup ledger: $PASSED passed, $FAILED failed"
    exit 1
fi
