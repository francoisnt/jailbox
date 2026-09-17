#!/bin/bash
# Sourced by the real-engine matrix. Fault points are discovered from a healthy
# command's persistent operations; expectations below come from lifecycle
# contracts. These are selected operation boundaries, not every internal write.

fault_baseline() {
    local command="$1" policy="$2" contract
    contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]-}
    case "$contract:$policy" in
        launch:resume)
            construct stopped-egress egress false false
            ;;
        launch:plain-network)
            construct home-false-false plain false false
            ;;
        launch:none)
            construct absent egress none false
            ;;
        launch:new-ephemeral)
            construct absent egress none true
            ;;
        launch:false)
            construct home-false-false egress false false
            ;;
        stop:false|stop:true|clean:false|clean:true)
            construct running egress "$policy" "$policy"
            ;;
        *) matrix_die "No starting state defined for $command:$policy" ;;
    esac
}

# An independent inventory oracle for dynamically constructed interruption
# rows. This reads the fixture engine directly, never jailbox's status output.
fault_inventory() {
    local name kind present=false
    local -a names=()
    if exists container "$PREFIX" &&
        [[ $(podman container inspect "$PREFIX" --format '{{.State.Running}}') = true ]]; then
        printf 'running\n'; return
    fi
    for kind in container network volume; do
        case "$kind" in
            container) names=("$PREFIX" "$PREFIX-proxy") ;;
            network) names=("$NETWORK" "$NETWORK-internal" "$NETWORK-external") ;;
            volume) names=("$HOME_VOLUME") ;;
        esac
        for name in "${names[@]}"; do
            if exists "$kind" "$name"; then present=true; fi
        done
    done
    if [[ "$present" = true ]]; then printf 'stopped\n'; else printf 'absent\n'; fi
}

assert_partial_cleanup() {
    local policy="$1" command="$2" name contract
    contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]}
    if exists container "$PREFIX"; then
        [[ -f "$GENERATION/key" && -f "$GENERATION/container-id" ]] || matrix_die 'cleanup removed authentication before development container'
        require_present volume "$HOME_VOLUME"
        require_present network "$NETWORK-internal"
    fi
    if exists container "$PREFIX-proxy"; then
        require_present network "$NETWORK-internal"
        require_present network "$NETWORK-external"
        require_present volume "$HOME_VOLUME" # Home follows both containers.
    fi
    if ! exists volume "$HOME_VOLUME"; then
        for name in "$NETWORK" "$NETWORK-internal" "$NETWORK-external"; do require_absent network "$name"; done
    elif [[ "$policy" = false ]]; then
        assert_marker keep
    fi
    if [[ "$contract" = stop && "$policy" = false ]]; then require_present volume "$HOME_VOLUME"; fi
}

interrupt_at_barrier() {
    local command="$1" ready token log_fd log_pid
    export LIFECYCLE_READY="$FIXTURE/ready" LIFECYCLE_RELEASE="$FIXTURE/release"
    rm -f "$LIFECYCLE_READY" "$LIFECYCLE_RELEASE"
    mkfifo "$LIFECYCLE_READY" "$LIFECYCLE_RELEASE"
    # Opening read/write prevents FIFO open itself from being an unbounded wait.
    exec {ready}<> "$LIFECYCLE_READY"
    exec {log_fd}> >(test_timestamp_stream > "$LOG/$CASE_KEY.command")
    log_pid=$!
    ledger_start_worker cli_exec "$command" >&"$log_fd" 2>&1 {log_fd}>&- || matrix_die 'could not register interrupted command'
    exec {log_fd}>&-
    ACTIVE_PID="$LEDGER_WORKER_PID"
    if ! IFS= read -r -t 60 token <&"$ready"; then
        kill -KILL -- "-$ACTIVE_PID" 2>/dev/null || true
        wait "$ACTIVE_PID" 2>/dev/null || true
        ACTIVE_PID=""
        matrix_die 'mutation barrier was not reached'
    fi
    [[ "$token" = ready ]] || matrix_die 'invalid barrier notification'
    # Kill the whole isolated command group, including preparation subshells
    # and the paused wrapper. No orphan child can mutate after the snapshot.
    kill -KILL -- "-$ACTIVE_PID"
    wait "$ACTIVE_PID" 2>/dev/null || true
    ACTIVE_PID=""
    wait "$log_pid" || matrix_die 'could not finish interrupted command log'
    exec {ready}>&-
}

run_mutation_faults() {
    local command="$1" policy="$2" count point fault result inventory recovery retained trace event contract
    local dev_id proxy_id home_preexisting
    # recovery holds the actual CLI command to execute, not a contract name.
    validate_lifecycle_contracts
    contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]}
    # New-home and pre-existing-home launches exercise distinct rollback
    # ownership. Cleanup exercises stored persistent and ephemeral policy.
    matrix_case_begin "trace.$command.$policy"
    trace="$LOG/$CASE_KEY.events"
    fault_baseline "$command" "$policy"
    export LIFECYCLE_EVENTS="$LOG/events"
    : > "$LIFECYCLE_EVENTS"
    expect_success "$command"
    cp "$LIFECYCLE_EVENTS" "$trace"
    count=$(wc -l < "$LIFECYCLE_EVENTS")
    unset LIFECYCLE_EVENTS
    lifecycle_require_fault_coverage "$trace" "$command" "$policy" || matrix_die 'persistent mutation coverage regressed'
    lifecycle_fault_cases "$trace" "$command" "$policy" >> "$LOG/expected-faults"
    matrix_case_pass
    for ((point=1; point<=count; point++)); do
        event=$(sed -n "${point}p" "$trace")
        lifecycle_fault_event_applies "$policy" "$event" || continue
        for fault in before after barrier; do
            # Allocation is covered before creation and by killing the
            # caller after allocation, before it receives the path. Do
            # not invent a failed mktemp that prints a success result.
            if [[ "$event" = mktemp\ * && "$fault" = after ]]; then continue; fi
            matrix_case_begin "interrupt.$command.$policy.$point.$fault"
            fault_baseline "$command" "$policy"
            home_preexisting=false
            if exists volume "$HOME_VOLUME"; then home_preexisting=true; fi
            if [[ "$policy" = resume ]]; then
                dev_id=$(podman container inspect "$PREFIX" --format '{{.Id}}')
                proxy_id=$(podman container inspect "$PREFIX-proxy" --format '{{.Id}}')
                podman network inspect "$NETWORK-internal" "$NETWORK-external" --format '{{.ID}}' > "$LOG/networks-before"
                filesystem_snapshot "$GENERATION" > "$LOG/generation-before"
            fi
            export LIFECYCLE_EVENTS="$LOG/events" LIFECYCLE_FAULT_AT="$point" LIFECYCLE_FAULT_MODE="$fault"
            : > "$LIFECYCLE_EVENTS"
            result=0
            if [[ "$fault" = barrier ]]; then
                interrupt_at_barrier "$command"
                result=137
            else
                test_log_capture "$LOG/$CASE_KEY.command" cli "$command" || result=$?
            fi
            cp "$LIFECYCLE_EVENTS" "$LOG/$CASE_KEY.events"
            [[ $(wc -l < "$LIFECYCLE_EVENTS") -ge "$point" ]] || matrix_die 'fault point not reached'
            lifecycle_same_fault_event "$trace" "$LIFECYCLE_EVENTS" "$point" || matrix_die 'fault point reached a different operation'
            unset LIFECYCLE_EVENTS LIFECYCLE_FAULT_AT LIFECYCLE_FAULT_MODE
            inventory=$(fault_inventory) || matrix_die "could not observe interrupted inventory"
            matrix_observe_fault interrupted
            if [[ "$contract" = launch ]]; then
                if [[ "$home_preexisting" = true ]]; then assert_marker keep; fi
                if [[ "$policy" = resume ]]; then
                    [[ $(podman container inspect "$PREFIX" --format '{{.Id}}') = "$dev_id" ]] || matrix_die 'interrupted resume replaced development survivor'
                    [[ $(podman container inspect "$PREFIX-proxy" --format '{{.Id}}') = "$proxy_id" ]] || matrix_die 'interrupted resume replaced proxy survivor'
                    podman network inspect "$NETWORK-internal" "$NETWORK-external" --format '{{.ID}}' > "$LOG/networks-after"
                    cmp -s "$LOG/networks-before" "$LOG/networks-after" || matrix_die 'interrupted resume replaced networks'
                    filesystem_snapshot "$GENERATION" > "$LOG/generation-after"
                    cmp -s "$LOG/generation-before" "$LOG/generation-after" || matrix_die 'interrupted resume changed credentials'
                    if grep -Eq '^podman (stop|rm) ' "$LOG/$CASE_KEY.events"; then matrix_die 'interrupted resume removed or stopped survivors'; fi
                    [[ "$result" != 0 ]] || assert_service
                elif [[ "$result" = 0 ]]; then
                    # Some idempotent operations can confirm success even
                    # after a tool reports failure. Success still owes all
                    # readiness checks, not merely surviving resources.
                    assert_service
                elif [[ "$fault" != barrier ]]; then
                    require_absent container "$PREFIX"
                    require_absent container "$PREFIX-proxy"
                    require_absent network "$NETWORK-internal"
                    require_absent network "$NETWORK-external"
                    require_absent network "$NETWORK"
                    [[ ! -e "$GENERATION" ]] || matrix_die 'handled failure left generation material'
                    if compgen -G "$STATE/.ssh-generation.*" >/dev/null; then matrix_die 'handled failure left partial generation'; fi
                    if [[ "$home_preexisting" = false ]]; then require_absent volume "$HOME_VOLUME"; fi
                fi
                recovery=stop
                retained=new
                if [[ "$home_preexisting" = true ]]; then retained=keep; fi
            else
                assert_partial_cleanup "$policy" "$command"
                recovery="$command"
                retained=delete
                if [[ "$contract:$policy" = stop:false ]]; then retained=keep; fi
            fi
            # These cases have valid home metadata. Stop/clean is the
            # owning recovery for interrupted operations; execute it.
            expect_success "$recovery"
            if [[ "$contract:$policy" = launch:new-ephemeral ]]; then require_absent volume "$HOME_VOLUME"; fi
            if [[ "$contract" != launch ]]; then assert_cleanup "$command" "$policy"; fi
            expect_success up
            assert_service
            if [[ "$contract:$policy" = launch:none ]]; then
                # Forced termination may leave a newly created persistent
                # home, but it had no pre-existing user marker to retain.
                assert_marker new
            else
                assert_marker "$retained"
            fi
            matrix_observe recovered running allow
            matrix_case_pass
        done
    done
}

run_failed_resume() {
    local policy missing before_id before_proxy observed
    for policy in false true; do
        for missing in false true; do
            matrix_case_begin "failed-resume.$policy.missing-proxy-$missing"
            construct stopped-ephemeral egress "$policy" "$policy"
            if [[ "$missing" = true ]]; then podman rm -f "$PREFIX-proxy" >/dev/null; fi
            before_id=$(podman container inspect "$PREFIX" --format '{{.Id}}')
            before_proxy=""
            if [[ "$missing" = false ]]; then before_proxy=$(podman container inspect "$PREFIX-proxy" --format '{{.Id}}'); fi
            filesystem_snapshot "$GENERATION" > "$LOG/generation-before"
            export LIFECYCLE_FAIL_SSH=true LIFECYCLE_EVENTS="$LOG/events"
            : > "$LIFECYCLE_EVENTS"
            if test_log_capture "$LOG/$CASE_KEY.command" cli up; then matrix_die 'injected readiness failure succeeded'; fi
            cp "$LIFECYCLE_EVENTS" "$LOG/$CASE_KEY.events"
            unset LIFECYCLE_FAIL_SSH LIFECYCLE_EVENTS
            grep -Fxq "podman start $PREFIX" "$LOG/$CASE_KEY.events" || matrix_die 'readiness failure did not follow survivor start'
            if grep -Eq '^podman (stop|rm) ' "$LOG/$CASE_KEY.events"; then matrix_die 'failed resume attempted to stop or remove a survivor/dependency'; fi
            [[ $(podman container inspect "$PREFIX" --format '{{.Id}}') = "$before_id" ]] || matrix_die 'failed resume replaced survivor'
            filesystem_snapshot "$GENERATION" > "$LOG/generation-after"
            cmp -s "$LOG/generation-before" "$LOG/generation-after" || matrix_die 'failed resume changed SSH generation'
            require_present container "$PREFIX-proxy"
            if [[ "$missing" = false ]]; then
                [[ $(podman container inspect "$PREFIX-proxy" --format '{{.Id}}') = "$before_proxy" ]] || matrix_die 'failed resume replaced proxy survivor'
            else
                grep -q 'Retained dependency' "$LOG/$CASE_KEY.command" || matrix_die 'missing retained dependency diagnosis'
            fi
            observed=$(podman container inspect "$PREFIX" --format '{{.State.Status}}')
            lifecycle_reports_state "$LOG/$CASE_KEY.command" "$PREFIX" "$observed" || matrix_die 'diagnosis differs from final observed state'
            assert_marker keep
            matrix_observe_fault failed-resume
            grep -q 'jailbox stop' "$LOG/$CASE_KEY.command" || matrix_die 'missing explicit recovery'
            expect_success stop
            assert_cleanup stop "$policy"
            expect_success up
            assert_service
            if [[ "$policy" = false ]]; then assert_marker keep; else assert_marker delete; fi
            matrix_observe recovered running allow
            matrix_case_pass
        done
    done
}

run_removal_failure() {
    local point
    matrix_case_begin failed-new-container-cleanup
    fault_baseline up false
    export LIFECYCLE_EVENTS="$LOG/events"
    : > "$LIFECYCLE_EVENTS"
    expect_success up
    # Locate the development creation operation by its exact --name argument,
    # independently of helper launches and proxy creation.
    point=$(awk -v name="$PREFIX" '$1 == "podman" && $2 == "run" { for (i=3;i<NF;i++) if ($i == "--name" && $(i+1) == name) print NR }' "$LIFECYCLE_EVENTS")
    cp "$LIFECYCLE_EVENTS" "$LOG/$CASE_KEY.reference"
    unset LIFECYCLE_EVENTS
    [[ "$point" =~ ^[0-9]+$ ]] || matrix_die 'development creation event missing'
    fault_baseline up false
    export LIFECYCLE_EVENTS="$LOG/events" LIFECYCLE_FAULT_AT="$point" LIFECYCLE_FAULT_MODE=after LIFECYCLE_FAIL_REMOVE=true
    : > "$LIFECYCLE_EVENTS"
    if test_log_capture "$LOG/$CASE_KEY.command" cli up; then matrix_die 'creation failure succeeded'; fi
    lifecycle_same_fault_event "$LOG/$CASE_KEY.reference" "$LIFECYCLE_EVENTS" "$point" || matrix_die 'creation fault reached a different operation'
    unset LIFECYCLE_EVENTS LIFECYCLE_FAULT_AT LIFECYCLE_FAULT_MODE LIFECYCLE_FAIL_REMOVE
    require_present container "$PREFIX"
    require_present container "$PREFIX-proxy"
    require_present network "$NETWORK-internal"
    require_present network "$NETWORK-external"
    [[ -f "$GENERATION/key" && -f "$GENERATION/container-id" ]] || matrix_die 'failed container removal lost credentials'
    grep -q 'cleanup could not remove' "$LOG/$CASE_KEY.command" || matrix_die 'missing incomplete-cleanup diagnosis'
    assert_marker keep
    matrix_observe_fault failed-cleanup
    expect_success stop
    expect_success up
    assert_service
    assert_marker keep
    matrix_observe recovered running allow
    matrix_case_pass
}

run_existing_dependency_failure() {
    local baseline proxy_id name
    for baseline in networks-only missing-dev; do
        matrix_case_begin "failed-create.$baseline"
        construct "$baseline" egress false false
        proxy_id=""
        if exists container "$PREFIX-proxy"; then proxy_id=$(podman container inspect "$PREFIX-proxy" --format '{{.Id}}'); fi
        for name in "$NETWORK-internal" "$NETWORK-external"; do
            podman network inspect "$name"
        done > "$LOG/networks-before"
        find "$STATE" -type f -exec sha256sum {} + | LC_ALL=C sort > "$LOG/material-before"
        export LIFECYCLE_FAIL_SSH=true
        if test_log_capture "$LOG/$CASE_KEY.command" cli up; then matrix_die 'new-generation readiness failure succeeded'; fi
        unset LIFECYCLE_FAIL_SSH
        require_absent container "$PREFIX"
        [[ ! -e "$GENERATION" ]] || matrix_die 'failed new generation retained credentials'
        if [[ -n "$proxy_id" ]]; then
            [[ $(podman container inspect "$PREFIX-proxy" --format '{{.Id}}') = "$proxy_id" ]] || matrix_die 'rollback replaced proxy survivor'
        else
            require_absent container "$PREFIX-proxy"
        fi
        for name in "$NETWORK-internal" "$NETWORK-external"; do
            podman network inspect "$name"
        done > "$LOG/networks-after"
        cmp -s "$LOG/networks-before" "$LOG/networks-after" || matrix_die 'rollback changed pre-existing networks'
        find "$STATE" -type f -exec sha256sum {} + | LC_ALL=C sort > "$LOG/material-after"
        cmp -s "$LOG/material-before" "$LOG/material-after" || matrix_die 'rollback changed pre-existing runtime content'
        assert_marker keep
        matrix_observe failed-create stopped refuse
        grep -q 'jailbox stop' "$LOG/$CASE_KEY.command" || matrix_die 'missing explicit recovery'
        expect_success stop
        expect_success up
        assert_service
        assert_marker keep
        matrix_observe recovered running allow
        matrix_case_pass
    done
}

run_home_inspection_failure() {
    local policy command retained contract
    validate_lifecycle_contracts
    for policy in false true; do
        for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
            contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]}
            matrix_case_begin "home-inspection.$policy.$command"
            construct running egress "$policy" "$policy"
            snapshot > "$LOG/inspection-before"
            export LIFECYCLE_FAIL_HOME_INSPECT="$HOME_VOLUME" LIFECYCLE_EVENTS="$LOG/events"
            : > "$LIFECYCLE_EVENTS"
            matrix_observe inspection-error running refuse
            if [[ "$contract" = clean ]]; then
                # Explicit clean does not depend on reading retention metadata.
                expect_success "$command"
            else
                if test_log_capture "$LOG/$CASE_KEY.command" cli "$command"; then matrix_die 'home inspection failure was ignored'; fi
                [[ ! -s "$LIFECYCLE_EVENTS" ]] || matrix_die 'inspection failure attempted lifecycle mutation'
                snapshot > "$LOG/inspection-after"
                cmp -s "$LOG/inspection-before" "$LOG/inspection-after" || matrix_die 'inspection failure changed existing state'
                grep -Eiq 'inspect.*retention|retention.*inspect' "$LOG/$CASE_KEY.command" || matrix_die 'missing operational inspection diagnosis'
                if grep -Eq 'jailbox (stop|--clean)' "$LOG/$CASE_KEY.command"; then matrix_die 'inspection error recommended destructive recovery'; fi
            fi
            unset LIFECYCLE_FAIL_HOME_INSPECT LIFECYCLE_EVENTS
            # Resolve the engine error and retry the requested command; do not
            # substitute corrupt-label cleanup for an operational failure.
            if [[ "$contract" != clean ]]; then expect_success "$command"; fi
            if [[ "$contract" != launch ]]; then assert_cleanup "$command" "$policy"; fi
            retained=delete
            if [[ "$contract" = launch || "$contract:$policy" = stop:false ]]; then retained=keep; fi
            expect_success up
            assert_service
            assert_marker "$retained"
            matrix_observe recovered running allow
            matrix_case_pass
        done
    done
}

# Faults interrupt known-good creation/resume/cleanup, not arbitrary policy
# edits. Independently inspect the remaining completeness and live services;
# never infer health from status or the failed launch's return code.
fault_attachment() {
    local name subnet url="" attempt running recorded actual
    for name in "$PREFIX" "$PREFIX-proxy"; do
        if [[ "$name" = "$PREFIX-proxy" && -z ${JAILBOX_CONFIG_EGRESS_ALLOW_0:-} ]]; then continue; fi
        if ! exists container "$name"; then
            printf 'refuse\n'; return
        fi
        running=$(podman container inspect "$name" --format '{{.State.Running}}') || matrix_die "cannot inspect fault running state"
        if [[ "$running" != true ]]; then
            printf 'refuse\n'; return
        fi
    done
    if [[ ! -f "$GENERATION/container-id" || ! -f "$GENERATION/ssh_config" ]]; then
        printf 'refuse\n'; return
    fi
    recorded=$(cat "$GENERATION/container-id") || matrix_die 'cannot read fault receipt'
    actual=$(podman container inspect "$PREFIX" --format '{{.Id}}') || matrix_die 'cannot inspect fault identity'
    if [[ "$recorded" != "$actual" ]]; then printf 'refuse\n'; return; fi
    if [[ -n ${JAILBOX_CONFIG_EGRESS_ALLOW_0:-} ]]; then
        subnet=$(podman network inspect "$NETWORK-internal" --format '{{(index .Subnets 0).Subnet}}') || matrix_die 'cannot inspect fault subnet'
        url="http://${subnet%.0/24}.2:8888"
    fi
    for attempt in 1 2 3; do
        if ssh -F "$GENERATION/ssh_config" -o ConnectTimeout=3 "$PREFIX" true >/dev/null 2>&1; then break; fi
        if [[ "$attempt" = 3 ]]; then printf 'refuse\n'; return; fi
        sleep 1
    done
    if [[ -n "$url" ]]; then
        if ! podman exec "$PREFIX" sh -c '
            grep -F "$1" "$HOME/.curlrc" >/dev/null &&
            grep -F "$1" "$HOME/.wgetrc" >/dev/null &&
            response=$(curl -q --noproxy "" --proxy "$1" -s --connect-timeout 3 --max-time 8 -o /dev/null -w "%{http_code}" http://jailbox-fault-check.invalid/) &&
            test "$response" = 403
        ' _ "$url"; then printf 'refuse\n'; return; fi
    fi
    printf 'allow\n'
}

matrix_observe_fault() {
    local inventory attachment
    inventory=$(fault_inventory) || matrix_die 'could not observe fault inventory'
    attachment=$(fault_attachment) || matrix_die 'could not establish fault attachment expectation'
    matrix_observe "$1" "$inventory" "$attachment"
}
