#!/bin/bash
# shellcheck source=src/public-api.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/host/api-support.sh"
initialize_public_api_lookups

# Contracts select explicit state/recovery assertions and independent required
# operations. Sharing a contract is a claim of equivalent lifecycle behavior.
# Launch uses each row's success/refusal expectation. Standalone stop and clean
# cases must succeed, with their distinct retention and removal guarantees.
declare -A LIFECYCLE_COMMAND_CONTRACTS=(
    [up]=launch [stop]=stop [--clean]=clean
)
declare -A LIFECYCLE_FAULT_SCENARIOS=(
    [up]='false none new-ephemeral resume plain-network home-setup' [stop]='false true' [--clean]='false true'
)
# Long sweeps run as several jobs, possibly on different machines. Each piece
# records its own trace and takes one contiguous share of the selected steps;
# the run, or the CI check across shards, verifies that all pieces recorded the
# same operations in order.
declare -A LIFECYCLE_FAULT_PIECES=(
    [up:false]=4 [up:none]=4 [stop:false]=2
)

validate_lifecycle_contracts() {
    local command policy scenario
    local -a policies=()
    local -A seen=() declared=()
    public_api_validate_mapping 'lifecycle command contracts' CLI_LIFECYCLE_COMMANDS LIFECYCLE_COMMAND_CONTRACTS
    public_api_validate_mapping 'lifecycle fault scenarios' CLI_LIFECYCLE_COMMANDS LIFECYCLE_FAULT_SCENARIOS
    for command in "${CLI_LIFECYCLE_COMMANDS[@]}"; do
        case "${LIFECYCLE_COMMAND_CONTRACTS[$command]}" in
            launch|stop|clean) ;;
            *) public_api_error "unknown lifecycle contract for '$command'" ;;
        esac
        read -r -a policies <<< "${LIFECYCLE_FAULT_SCENARIOS[$command]}"
        [[ -n "${policies[*]}" ]] || public_api_error "no fault scenarios for '$command'"
        seen=()
        for policy in "${policies[@]}"; do
            [[ "$policy" =~ ^[a-z][a-z-]*$ ]] || public_api_error "invalid fault scenario for '$command'"
            [[ ! -v seen[$policy] ]] || public_api_error "duplicate fault scenario '$command:$policy'"
            seen[$policy]=1
            lifecycle_fault_requirements "$command" "$policy" >/dev/null || public_api_error "missing fault requirements for '$command:$policy'"
            declared[$command:$policy]=1
        done
    done
    for scenario in "${!LIFECYCLE_FAULT_PIECES[@]}"; do
        [[ -v declared[$scenario] ]] || public_api_error "split fault scenario '$scenario' is not declared"
        [[ "${LIFECYCLE_FAULT_PIECES[$scenario]}" =~ ^[2-9]$ ]] || public_api_error "invalid piece count for '$scenario'"
    done
}

# Number of jobs a fault scenario runs as; unsplit scenarios run as one.
lifecycle_fault_piece_count() {
    printf '%s\n' "${LIFECYCLE_FAULT_PIECES[$1:$2]-1}"
}

# Focused scenarios sweep the steps that distinguish their recovery behavior.
# Keep original trace positions so fault injection still reaches the same call.
# --clean removes containers and networks through the same shared probe and
# removal helpers as stop, so its sweep breaks only its own removals: the home,
# the images and the project state. Rows still run --clean from partial states.
lifecycle_fault_event_applies() {
    local command="$1" policy="$2" event="$3"
    case "${LIFECYCLE_COMMAND_CONTRACTS[$command]}:$policy" in
        launch:resume) [[ "$event" = podman\ start\ * ]] ;;
        launch:plain-network) [[ "$event" = podman\ network\ create\ * && "$event" = *-net ]] ;;
        launch:home-setup) [[ "$event" = ssh\ *jailbox-exec-argv* || "$event" = mv\ *home-setup-complete* ]] ;;
        launch:new-ephemeral)
            [[ "$event" = podman\ volume\ create\ * || "$event" = podman\ run\ *\ --cidfile\ * ]]
            ;;
        stop:true)
            [[ "$event" = podman\ volume\ rm\ * || "$event" = rm\ -rf\ --\ */ssh-generation\ * ]]
            ;;
        clean:true) [[ "$event" = podman\ volume\ rm\ * ]] ;;
        clean:false)
            [[ "$event" = podman\ volume\ rm\ * || "$event" = podman\ image\ rm\ * || "$event" = rm\ -rf\ --\ * ]]
            ;;
        *) return 0 ;;
    esac
}

# Independently maintained coverage floors for the healthy fault fixtures.
# These describe operation roles, not a total derived from the current trace.
# Full sweeps include new operations automatically. Removing or replacing a
# required operation needs an explicit review, even if the command still works.
lifecycle_fault_requirements() {
    local command="$1" policy="$2" contract
    local -a requirements=()
    [[ "$command" =~ ^-{0,2}[A-Za-z][A-Za-z0-9-]*$ ]] || return 1
    contract=${LIFECYCLE_COMMAND_CONTRACTS[$command]-}
    case "$contract:$policy" in
        launch:resume)
            requirements=(
                'development-start|1|^podman start jailbox-project-[[:xdigit:]]+$'
                'proxy-start|1|^podman start .*-proxy$'
            )
            ;;
        launch:plain-network)
            requirements=('plain-network|1|^podman network create .* [^ ]+-net$')
            ;;
        launch:home-setup)
            requirements=(
                'setup-execution|1|^ssh .*jailbox-exec-argv'
                'setup-record-publication|1|^mv .* /.*home-setup-complete$'
            )
            ;;
        launch:new-ephemeral)
            requirements=(
                'home-creation-and-ownership|1|^podman volume create .* --opt o=uid=0\\,gid=0 '
                'development-container|1|^podman run .* --cidfile '
            )
            ;;
        launch:false|launch:none)
            requirements=(
                'internal-network|1|^podman network create .* [^ ]+-net-internal$'
                'external-network|1|^podman network create .* [^ ]+-net-external$'
                'proxy-container|1|^podman run .* --name [^ ]+-proxy '
                'development-container|1|^podman run .* --cidfile '
                'state-directories|4|^mkdir -p '
                'proxy-filter-permissions|1|^chmod 644 .*/tinyproxy-filter$'
                'proxy-config-permissions|1|^chmod 644 .*/tinyproxy[.]conf$'
                'gitconfig-allocation|1|^mktemp .*/gitconfig[.]tmp[.]'
                'gitconfig-staging-permissions|1|^chmod 600 .*/gitconfig[.]tmp[.]'
                'gitconfig-publication|1|^mv .*/gitconfig[.]tmp[.].* /.*gitconfig$'
                'ssh-allocation|1|^mktemp -d .*/[.]ssh-generation[.]'
                'ssh-server-directory|1|^mkdir .*/[.]ssh-generation[.][^ /]+/server$'
                'ssh-client-key|1|^ssh-keygen .* -C jailbox-client '
                'ssh-server-key|1|^ssh-keygen .* -C jailbox-server '
                'ssh-authorization|1|^cp .*/server/authorized_keys$'
                'ssh-private-permissions|1|^chmod 600 .*/server/authorized_keys$'
                'ssh-public-permissions|1|^chmod 644 .*/server/ssh_host_ed25519_key[.]pub$'
                'ssh-publication|1|^mv .*/[.]ssh-generation[.].* /.*ssh-generation$'
                'ssh-staging-cleanup|1|^rm .*/[.]ssh-generation[.][^ /]+$'
                'launch-write-probes|1|^ssh .*bash.*-s.*--.*launch'
                'proxy-session-configuration|1|^ssh .*jailbox-manage-proxy.*enable'
            )
            if [[ "$policy" != false ]]; then
                requirements+=(
                    'home-creation-and-ownership|1|^podman volume create .* --opt o=uid=0\\,gid=0 '
                )
            fi
            ;;
        stop:true)
            requirements=(
                'home-removal|1|^podman volume rm .*-home$'
                'ssh-removal|1|^rm -rf -- .*/ssh-generation '
            )
            ;;
        clean:true)
            requirements=('home-removal|1|^podman volume rm .*-home$')
            ;;
        stop:false|clean:false)
            requirements=(
                'development-stop|1|^podman stop jailbox-project-[[:xdigit:]]+$'
                'proxy-stop|1|^podman stop .*-proxy$'
                'development-removal|1|^podman rm jailbox-project-[[:xdigit:]]+$'
                'proxy-removal|1|^podman rm .*-proxy$'
                'internal-network-removal|1|^podman network rm .*-net-internal$'
                'external-network-removal|1|^podman network rm .*-net-external$'
            )
            if [[ "$contract" = clean ]]; then
                requirements+=(
                    'home-removal|1|^podman volume rm .*-home$'
                    'development-image-removal|1|^podman image rm .*-image$'
                    'proxy-image-removal|1|^podman image rm .*-proxy$'
                    'state-removal|1|^rm -rf -- .*/projects/[[:xdigit:]]+$'
                )
            else
                requirements+=('ssh-removal|1|^rm -rf -- .*/ssh-generation ')
            fi
            ;;
        *) printf 'Unknown fault coverage scenario: %s:%s\n' "$command" "$policy" >&2; return 1 ;;
    esac
    printf '%s\n' "${requirements[@]}"
}

# Each SSH row runs its own launch refusal and stop recovery. Standalone
# cleanup also covers missing and unusual path types and a directory mode.
lifecycle_row_case_applies() {
    local row="${1%.*}" command="${1##*.}"
    case "$row" in
        ssh-missing|ssh-symlink|ssh-directory|ssh-fifo|ssh-parent-mode) return 0 ;;
        ssh-*)
            [[ "$command" =~ ^-{0,2}[A-Za-z][A-Za-z0-9-]*$ &&
                ${LIFECYCLE_COMMAND_CONTRACTS[$command]-} = launch ]]
            ;;
        *) return 0 ;;
    esac
}

# Each concrete SSH defect still owes refusal, non-mutation, and safe cleanup.
# Once cleanup proves the same retained-home baseline, these representatives
# supply the full relaunch/transport proof. Metadata and key-content defects
# retain separate representatives. Unlisted rows retain comprehensive recovery.
declare -A LIFECYCLE_RECOVERY_REPRESENTATIVES=(
    [ssh-missing]=ssh-mode [ssh-symlink]=ssh-mode [ssh-directory]=ssh-mode
    [ssh-fifo]=ssh-mode [ssh-owner]=ssh-mode [ssh-mode]=ssh-mode
    [ssh-parent-mode]=ssh-mode
    [ssh-server-pair]=ssh-client-pair [ssh-client-pair]=ssh-client-pair
    [ssh-authorized]=ssh-client-pair [ssh-pin]=ssh-client-pair
    [ssh-config]=ssh-client-pair
)

validate_lifecycle_recovery_contracts() {
    local rows key signature representative
    local -A signatures=()
    rows=$(lifecycle_matrix_rows) || return 1
    while IFS='|' read -r key signature; do
        [[ "$key" =~ ^[a-z][a-z0-9-]*$ ]] || { printf 'Invalid recovery row\n' >&2; return 1; }
        [[ ! -v signatures[$key] ]] || { printf 'Duplicate recovery row\n' >&2; return 1; }
        signatures[$key]=$signature
    done <<< "$rows"
    for key in "${!LIFECYCLE_RECOVERY_REPRESENTATIVES[@]}"; do
        [[ "$key" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
        representative=${LIFECYCLE_RECOVERY_REPRESENTATIVES[$key]}
        [[ "$representative" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
        if [[ ! -v signatures[$key] || ! -v signatures[$representative] ||
              ${LIFECYCLE_RECOVERY_REPRESENTATIVES[$representative]-} != "$representative" ]]; then
            printf 'Missing or indirect recovery representative for %s\n' "$key" >&2; return 1
        fi
        # Equivalence concerns the complete independently authored row contract,
        # not a verdict inferred from a production detector.
        if [[ ${signatures[$key]} = "${signatures[$representative]}" &&
              ${signatures[$key]} = 'plain|false|false|refuse|stopped|refuse|stop|keep|stopped' ]]; then
            continue
        else
            printf 'Non-equivalent recovery contract for %s\n' "$key" >&2; return 1
        fi
    done
}

lifecycle_recovery_representative() {
    [[ "$1" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    printf '%s\n' "${LIFECYCLE_RECOVERY_REPRESENTATIVES[$1]-$1}"
}
