#!/bin/bash
# Construct and assert one worker's independent lifecycle fixtures.

lifecycle_setup() {
    local tool variable
    FIXTURE="$1"
    LOG="$2"
    PROJECT="$FIXTURE/project"
    mkdir -p "$PROJECT" "$LOG" "$FIXTURE/bin" "$FIXTURE/real"
    # Capture the host ledger location before isolating project runtime state, so
    # interrupted cleanup remains recoverable even if the fixture disappears.
    export JAILBOX_TEST_LEDGER_DIR="${JAILBOX_TEST_LEDGER_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/jailbox-test-ledger}"
    export XDG_STATE_HOME="$FIXTURE/state"
    export LIFECYCLE_REAL_BIN="$FIXTURE/real"
    for tool in podman ssh ssh-keygen mkdir cp chmod mv rm mktemp; do
        ln -s "$(command -v "$tool")" "$LIFECYCLE_REAL_BIN/$tool"
        ln -s "$ROOT/tests/lib/lifecycle-fault.sh" "$FIXTURE/bin/$tool"
    done
    ledger_begin_run lifecycle-worker
    printf '%s\n' "$LEDGER_FILE" > "$LOG/ledger"
    ledger_record_project_resources "$PROJECT"
    PREFIX=$(jailbox_resource_prefix_for_path "$PROJECT")
    HASH=$(jailbox_project_hash_for_path "$PROJECT")
    STATE="$XDG_STATE_HOME/jailbox/projects/$HASH"
    GENERATION="$STATE/ssh-generation"
    HOME_VOLUME="$PREFIX-home"
    NETWORK="$PREFIX-net"
    EXTRA="$PREFIX-fixture-extra"
    ledger_record network "$EXTRA"
    ACTIVE_PID=""
    git -C "$PROJECT" init -q
    # shellcheck disable=SC2016 # Positional arguments belong to the child shell.
    test_log_capture "$LOG/init" bash -c 'cd "$1" && "$2" init' _ "$PROJECT" "$ROOT/jailbox"
    chmod 755 "$PROJECT"
    chmod 644 "$PROJECT/jailbox.conf"
    # Remove inherited launch policy: fixtures specify their entire policy.
    while IFS= read -r variable; do unset "$variable"; done < <(compgen -A variable JAILBOX_CONFIG_)
    export JAILBOX_CONFIG_DEV_IMAGE=jailbox-test-debian
    export JAILBOX_CONFIG_EPHEMERAL_HOME=false
    export JAILBOX_CONFIG_EGRESS_ALLOW=""
    CASE_KEY=setup

}

cli_exec() {
    # The pool ledger must also retain this owner if its worker is killed before
    # it can reap the separately isolated CLI process group.
    LEDGER_FILE="$LIFECYCLE_POOL_LEDGER" ledger_record_owner "$BASHPID" || exit 1
    cd "$PROJECT" || exit 1
    exec setsid env PATH="$FIXTURE/bin:$PATH" "$ROOT/jailbox" "$@"
}

matrix_case_begin() {
    CASE_KEY="$1"
    CASE_STARTED=$SECONDS
    lifecycle_case_label "$RUN" "$CASE_KEY"
}

matrix_case_pass() {
    printf '%s|%s\n' "$CASE_KEY" "$((SECONDS - CASE_STARTED))" >> "$LOG/cases"
    printf 'PASS [%s] %ds\n' "$CASE_KEY" "$((SECONDS - CASE_STARTED))"
    lifecycle_progress "$RUN"
}
cli() {
    local result=0
    ledger_start_worker cli_exec "$@" || return 1
    ACTIVE_PID="$LEDGER_WORKER_PID"
    wait "$ACTIVE_PID" || result=$?
    ACTIVE_PID=""
    return "$result"
}
exists() {
    local result=0
    podman "$1" exists "$2" || result=$?
    case "$result" in
        0|1) return "$result" ;;
        *) matrix_die "could not inspect $1 $2 (exit $result)" ;;
    esac
}
require_absent() { if exists "$1" "$2"; then matrix_die "unexpected surviving $1 $2"; fi; }
require_present() { exists "$1" "$2" || matrix_die "missing $1 $2"; }
image_snapshot() {
    local name
    for name in "$PREFIX-dev" "$PREFIX-image" "$PREFIX-proxy"; do
        if exists image "$name"; then
            printf '%s ' "$name"
            podman image inspect "$name" --format '{{.Id}}'
        fi
    done
}
expect_success() {
    test_log_capture "$LOG/$CASE_KEY.command" cli "$@" || {
        cat "$LOG/$CASE_KEY.command" >&2
        matrix_die "$* failed"
    }
}
volume_path() { podman volume inspect "$HOME_VOLUME" --format '{{.Mountpoint}}'; }
seed_home() {
    # In podman unshare, 0:0 maps to the invoking host user/group. keep-id
    # maps that host identity to the managed container user. Using the host's
    # numeric UID inside unshare instead assigns a subordinate host identity.
    podman unshare bash -c '
        set -euo pipefail
        chown 0:0 "$1"
        chmod 755 "$1"
        printf "retained\n" > "$1/lifecycle-marker"
        chmod 644 "$1/lifecycle-marker"
        [[ $(stat -c "%u:%g:%a" "$1") = 0:0:755 ]]
    ' _ "$(volume_path)"
}
assert_marker() {
    local expected="$1" path
    path=$(volume_path)
    if [[ "$expected" = keep ]]; then
        [[ $(podman unshare cat "$path/lifecycle-marker") = retained ]] || matrix_die 'home marker lost'
    elif podman unshare test -e "$path/lifecycle-marker"; then
        matrix_die 'deleted home contents survived recovery'
    fi
}
# Stable filesystem metadata and hashes, never key bytes. Do not follow symlinks
# or read FIFOs; access times change when inspected and are intentionally absent.
filesystem_snapshot() {
    podman unshare bash -c '
        set -euo pipefail
        [[ -e "$1" ]] || exit 0
        cd "$1"
        find . -printf "%P|%y|%U|%G|%m|%i|%s|%T@|%l\n" | LC_ALL=C sort
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ' _ "$1"
}
snapshot() {
    local kind name
    for kind in container network volume; do
        for name in "$PREFIX" "$PREFIX-proxy" "$NETWORK" "$NETWORK-internal" "$NETWORK-external" "$HOME_VOLUME"; do
            if exists "$kind" "$name"; then
                printf '%s:%s\n' "$kind" "$name"
                case "$kind" in
                    container)
                        podman container inspect "$name" --format '{{.Id}} {{.State.Status}} {{json .Config}} {{json .HostConfig}} {{json .Mounts}} {{json .NetworkSettings.Networks}}'
                        ;;
                    network) podman network inspect "$name" ;;
                    volume) podman volume inspect "$name" --format '{{.Name}} {{.CreatedAt}} {{json .Labels}} {{.Mountpoint}}' ;;
                esac
            fi
        done
    done
    filesystem_snapshot "$XDG_STATE_HOME"
    if exists volume "$HOME_VOLUME"; then filesystem_snapshot "$(volume_path)"; fi
    sha256sum "$PROJECT/jailbox.conf"
}
# Extension point for 03.2.08/09/09.1/09.2. Observe before any lifecycle
# mutation and after recovery. Expectations are passed, never computed from
# the implementation. Dynamic fault rows use 'health-dependent': attachment
# must follow final observed health, never the failed launch's exit status.
# The owning interface plans complete those assertions here, without treating
# these log records as executed diagnostic tests.
matrix_observe() {
    local phase="$1" status="$2" diagnosis="$3" attachment="$4"
    printf '%s|%s|%s|%s|%s\n' "$CASE_KEY" "$phase" "$status" "$diagnosis" "$attachment" >> "$LOG/observations"
}
network_disconnect() {
    local network="$1" name
    for name in "$PREFIX" "$PREFIX-proxy"; do
        if exists container "$name"; then
            podman network disconnect "$network" "$name" >/dev/null
        fi
    done
}
occupy_first_subnet() {
    local subnet="$1" name
    if podman network create --internal --subnet "$subnet" "$EXTRA" >/dev/null 2>&1; then return; fi
    # Another project may already occupy the candidate. Establish that fact
    # read-only instead of treating an arbitrary create failure as a collision.
    podman network ls --format '{{.Name}}' > "$LOG/network-names"
    while IFS= read -r name; do
        podman network inspect "$name" --format '{{range .Subnets}}{{println .Subnet}}{{end}}' > "$LOG/subnets"
        if grep -Fxq "$subnet" "$LOG/subnets"; then return; fi
    done < "$LOG/network-names"
    matrix_die 'could not establish a collision on the first subnet candidate'
}
construct() {
    local key="$1" mode="$2" policy="$3" requested="$4" offset subnet
    reset_fixture
    if [[ "$mode" = egress ]]; then
        unset JAILBOX_CONFIG_EGRESS_ALLOW
        export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
    fi
    case "$policy" in true|false) export JAILBOX_CONFIG_EPHEMERAL_HOME="$policy" ;; esac
    case "$key" in
        absent) ;;
        partial-ssh)
            mkdir -p "$STATE/.ssh-generation.interrupted"
            chmod 700 "$STATE" "$STATE/.ssh-generation.interrupted"
            printf partial > "$STATE/.ssh-generation.interrupted/key"
            ;;
        home-*|corrupt-and-digest)
            local -a labels=()
            case "$policy" in
                legacy) ;;
                empty) labels=(--label jailbox.ephemeral-home=) ;;
                corrupt) labels=(--label jailbox.ephemeral-home=garbage) ;;
                newline) labels=(--label $'jailbox.ephemeral-home=true\n') ;;
                *) labels=(--label "jailbox.ephemeral-home=$policy") ;;
            esac
            podman volume create "${labels[@]}" "$HOME_VOLUME" >/dev/null
            seed_home
            if [[ "$key" = corrupt-and-digest ]]; then
                podman create --name "$PREFIX" --network none --label jailbox.config-digest=invalid \
                    -v "$HOME_VOLUME:/home/jailbox" jailbox-test-debian true >/dev/null
            fi
            ;;
        *)
            if [[ "$key" = collision-fallback ]]; then
                offset=$(jailbox_project_hash_port_offset "$HASH")
                subnet="10.240.$((1 + offset % 200)).0/24"
                occupy_first_subnet "$subnet"
            fi
            expect_success up
            seed_home
            case "$key" in
                stopped|stopped-egress|stopped-ephemeral|ssh-*) podman stop "$PREFIX" >/dev/null ;;
            esac
            case "$key" in
                mixed) podman stop "$PREFIX-proxy" >/dev/null ;;
                stopped-egress) podman stop "$PREFIX-proxy" >/dev/null ;;
                networks-only) podman rm -f "$PREFIX" "$PREFIX-proxy" >/dev/null; rm -rf "$GENERATION" ;;
                missing-proxy) podman rm -f "$PREFIX-proxy" >/dev/null ;;
                missing-dev) podman rm -f "$PREFIX" >/dev/null; rm -rf "$GENERATION" ;;
                orphan-ssh) podman rm -f "$PREFIX" >/dev/null ;;
                missing-network)
                    podman network disconnect "$NETWORK" "$PREFIX"
                    podman network rm "$NETWORK" >/dev/null ;;
                missing-internal|missing-networks)
                    network_disconnect "$NETWORK-internal"
                    podman network rm "$NETWORK-internal" >/dev/null
                    if [[ "$key" = missing-networks ]]; then
                        podman network disconnect "$NETWORK-external" "$PREFIX-proxy"
                        podman network rm "$NETWORK-external" >/dev/null
                    fi ;;
                disconnected) podman network disconnect "$NETWORK-internal" "$PREFIX" ;;
                unexpected-attachment)
                    podman network create --internal "$EXTRA" >/dev/null
                    podman network connect "$EXTRA" "$PREFIX" ;;
                missing-digest|inconsistent-digest)
                    local -a labels=()
                    if [[ "$key" = inconsistent-digest ]]; then labels=(--label "jailbox.config-digest=$(printf '%064d' 0)"); fi
                    podman network create "${labels[@]}" "$NETWORK" >/dev/null ;;
                mismatched-digest) export JAILBOX_CONFIG_MEMORY_LIMIT=3g ;;
                mode-and-ssh) chmod 644 "$GENERATION/key" ;;
                managed-blocks)
                    podman exec "$PREFIX" sh -c 'printf "# user curl preference\n" > "$HOME/.curlrc"; printf "# user wget preference\n" > "$HOME/.wgetrc"'
                    ;;
                ssh-missing) rm "$GENERATION/key" ;;
                ssh-symlink) mv "$GENERATION/key" "$FIXTURE/saved-key"; ln -s "$FIXTURE/saved-key" "$GENERATION/key" ;;
                ssh-directory) rm "$GENERATION/key"; mkdir "$GENERATION/key" ;;
                ssh-fifo) rm "$GENERATION/key"; mkfifo "$GENERATION/key" ;;
                ssh-owner) podman unshare chown 1 "$GENERATION/key" ;;
                ssh-mode) chmod 644 "$GENERATION/key" ;;
                ssh-parent-mode) chmod 777 "$GENERATION/server" ;;
                ssh-server-pair) cp "$GENERATION/key.pub" "$GENERATION/server/ssh_host_ed25519_key.pub" ;;
                ssh-client-pair) cp "$GENERATION/server/ssh_host_ed25519_key.pub" "$GENERATION/key.pub" ;;
                ssh-authorized) printf 'altered\n' >> "$GENERATION/server/authorized_keys" ;;
                ssh-pin) printf '\n' >> "$GENERATION/known_hosts" ;;
                ssh-config) printf '    StrictHostKeyChecking no\n' >> "$GENERATION/ssh_config" ;;
            esac
            # No label writes occur here: mode changes invalidate the recorded
            # digest naturally, exercising home-first recovery precedence.
            ;;
    esac
    STATE_UNRELATED=false
    if [[ -d "$STATE" ]]; then
        printf 'unrelated runtime content\n' > "$STATE/unrelated"
        chmod 600 "$STATE/unrelated"
        STATE_UNRELATED=true
    fi
    export JAILBOX_CONFIG_EPHEMERAL_HOME="$requested"
}
assert_service() {
    local url subnet actual
    ssh -F "$GENERATION/ssh_config" -o ConnectTimeout=5 "$PREFIX" true || matrix_die 'strict SSH recovery failed'
    if [[ -n ${JAILBOX_CONFIG_EGRESS_ALLOW_0:-} ]]; then
        subnet=$(podman network inspect "$NETWORK-internal" --format '{{(index .Subnets 0).Subnet}}')
        url="http://${subnet%.0/24}.2:8888"
        actual=$(ssh -F "$GENERATION/ssh_config" "$PREFIX" 'printf "%s" "$HTTP_PROXY"')
        [[ "$actual" = "$url" ]] || matrix_die 'session proxy differs from live subnet'
        podman exec "$PREFIX" sh -c 'grep -F "$1" "$HOME/.curlrc" && grep -F "$1" "$HOME/.wgetrc"' _ "$url" >/dev/null || matrix_die 'managed proxy blocks differ from live subnet'
        if [[ "$CASE_KEY" = collision-fallback* ]]; then
            local offset
            offset=$(jailbox_project_hash_port_offset "$HASH")
            [[ "$subnet" != "10.240.$((1 + offset % 200)).0/24" ]] || matrix_die 'collision did not use fallback'
        fi
    fi
}
assert_cleanup() {
    local command="$1" policy="$2" name contract
    contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]}
    for name in "$PREFIX" "$PREFIX-proxy"; do require_absent container "$name"; done
    for name in "$NETWORK" "$NETWORK-internal" "$NETWORK-external"; do require_absent network "$name"; done
    [[ ! -e "$GENERATION" ]] || matrix_die 'generation survived cleanup'
    if compgen -G "$STATE/.ssh-generation.*" >/dev/null; then matrix_die 'partial generation survived cleanup'; fi
    if [[ "$contract" = clean || "$policy" = true || "$policy" = none ]]; then
        require_absent volume "$HOME_VOLUME"
    else
        require_present volume "$HOME_VOLUME"
        assert_marker keep
    fi
    if [[ "$contract" = clean ]]; then
        [[ ! -e "$STATE" ]] || matrix_die 'runtime state survived clean'
        for name in "$PREFIX-dev" "$PREFIX-image" "$PREFIX-proxy"; do require_absent image "$name"; done
    elif [[ "$STATE_UNRELATED" = true ]]; then
        [[ $(cat "$STATE/unrelated") = 'unrelated runtime content' ]] || matrix_die 'stop removed unrelated runtime content'
    fi
    require_present image jailbox-test-debian
}
run_row() {
    # The row's recovery names a repair action (stop/clean), not the command's
    # test contract. Refusal recovery deliberately invokes stop or --clean;
    # subsequent convergence executes the command under test again.
    local key="$1" mode="$2" policy="$3" requested="$4" up="$5" status="$6" diagnosis="$7" attach="$8" recovery="$9" retained="${10}" stopped="${11}" command
    local dev_id proxy_id generation_present extra_present contract
    validate_lifecycle_contracts
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]}
        matrix_case_begin "$key.$command"
        construct "$key" "$mode" "$policy" "$requested"
        if exists volume "$HOME_VOLUME"; then
            podman volume inspect "$HOME_VOLUME" --format '{{json .Labels}}' > "$LOG/home-labels-before"
        fi
        matrix_observe initial "$status" "$diagnosis" "$attach"
        if [[ "$contract" != launch ]]; then
            image_snapshot > "$LOG/images-before"
            extra_present=false
            if exists network "$EXTRA"; then extra_present=true; fi
            expect_success "$command"
            assert_cleanup "$command" "$policy"
            if [[ "$extra_present" = true ]]; then require_present network "$EXTRA"; fi
            if [[ "$contract" = stop ]]; then
                image_snapshot > "$LOG/images-after"
                cmp -s "$LOG/images-before" "$LOG/images-after" || matrix_die 'stop changed images'
                matrix_observe stopped "$stopped" cleanup refuse
            else
                matrix_observe cleaned absent absent refuse
            fi
            expect_success "$command" # Explicit cleanup is retryable.
            matrix_case_pass
            continue
        fi
        dev_id=""; proxy_id=""; generation_present=false
        if [[ "$up" = success ]]; then
            if exists container "$PREFIX"; then dev_id=$(podman container inspect "$PREFIX" --format '{{.Id}}'); fi
            if exists container "$PREFIX-proxy"; then proxy_id=$(podman container inspect "$PREFIX-proxy" --format '{{.Id}}'); fi
            if [[ -d "$GENERATION" ]]; then
                filesystem_snapshot "$GENERATION" > "$LOG/generation-before"
                generation_present=true
            fi
            if [[ "$attach" = allow ]]; then snapshot > "$LOG/noop-before"; fi
        fi
        if [[ "$up" = refuse ]]; then
            snapshot > "$LOG/before"
            if test_log_capture "$LOG/$CASE_KEY.command" cli "$command"; then matrix_die 'damaged state accepted'; fi
            snapshot > "$LOG/after"
            cmp -s "$LOG/before" "$LOG/after" || matrix_die 'compatibility refusal mutated pre-existing state'
            if [[ "$recovery" = clean ]]; then
                grep -q 'jailbox --clean' "$LOG/$CASE_KEY.command" || matrix_die 'missing clean recovery'
                grep -q 'permanently' "$LOG/$CASE_KEY.command" || matrix_die 'missing deletion warning'
                expect_success --clean
            else
                grep -q 'jailbox stop' "$LOG/$CASE_KEY.command" || matrix_die 'missing stop recovery'
                if [[ "$policy" = true && "$key" = home-* ]]; then
                    grep -Eiq 'orphan(ed)?.*ephemeral|ephemeral.*orphan(ed)?' "$LOG/$CASE_KEY.command" || matrix_die 'missing ephemeral-orphan diagnosis'
                fi
                expect_success stop
            fi
        fi
        expect_success "$command"
        if [[ -n "$dev_id" ]]; then
            [[ $(podman container inspect "$PREFIX" --format '{{.Id}}') = "$dev_id" ]] || matrix_die 'convergence replaced development survivor'
        fi
        if [[ -n "$proxy_id" ]]; then
            [[ $(podman container inspect "$PREFIX-proxy" --format '{{.Id}}') = "$proxy_id" ]] || matrix_die 'convergence replaced proxy survivor'
        fi
        if [[ "$generation_present" = true ]]; then
            filesystem_snapshot "$GENERATION" > "$LOG/generation-after"
            cmp -s "$LOG/generation-before" "$LOG/generation-after" || matrix_die 'convergence changed surviving generation'
        fi
        if [[ "$attach" = allow ]]; then
            snapshot > "$LOG/noop-after"
            cmp -s "$LOG/noop-before" "$LOG/noop-after" || matrix_die 'healthy reuse mutated sandbox'
        fi
        assert_service
        assert_marker "$retained"
        if [[ "$retained" = keep ]]; then
            podman volume inspect "$HOME_VOLUME" --format '{{json .Labels}}' > "$LOG/home-labels-after"
            cmp -s "$LOG/home-labels-before" "$LOG/home-labels-after" || matrix_die 'reuse rewrote home metadata'
        fi
        if [[ "$key" = managed-blocks ]]; then
            podman exec "$PREFIX" sh -c 'grep -q "# user curl preference" "$HOME/.curlrc" && grep -q "# user wget preference" "$HOME/.wgetrc"' || matrix_die 'managed sync lost user settings'
        fi
        matrix_observe recovered running healthy allow
        matrix_case_pass
    done
}
