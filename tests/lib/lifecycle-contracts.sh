#!/bin/bash
# shellcheck source=src/public.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/public.sh"
# shellcheck source=src/host/api-support.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/host/api-support.sh"
initialize_public_api_lookups

# Contracts select explicit state/recovery assertions and independent required
# operations. Sharing a contract is a claim of equivalent lifecycle behavior.
# Launch uses each row's success/refusal expectation; stop and clean must
# succeed in every row, with their distinct retention and removal guarantees.
declare -A LIFECYCLE_COMMAND_CONTRACTS=(
    [up]=launch [stop]=stop [--clean]=clean
)
declare -A LIFECYCLE_FAULT_SCENARIOS=(
    [up]='false none new-ephemeral resume plain-network' [stop]='false true' [--clean]='false true'
)

validate_lifecycle_contracts() {
    local command policy
    local -a policies=()
    local -A seen=()
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
        done
    done
}

# The extra scenarios sweep only operations absent from the creation sweeps.
# Keep original trace positions so fault injection still reaches the same call.
lifecycle_fault_event_applies() {
    local scenario="$1" event="$2"
    case "$scenario" in
        resume) [[ "$event" = podman\ start\ * ]] ;;
        plain-network) [[ "$event" = podman\ network\ create\ * && "$event" = *-net ]] ;;
        *) return 0 ;;
    esac
}

# Independently maintained coverage floors for the healthy fault fixtures.
# These describe operation roles, not a total derived from the current trace.
# New operations are still swept automatically. Removing or replacing a required
# operation needs an explicit review of this contract, even if launch still works.
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
        launch:false|launch:none|launch:new-ephemeral)
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
                'proxy-session-configuration|1|^ssh .*jailbox-manage-proxy.*enable'
            )
            if [[ "$policy" != false ]]; then
                requirements+=(
                    'home-creation|1|^podman volume create '
                    'home-ownership|1|^podman unshare chown '
                )
            fi
            ;;
        stop:false|stop:true|clean:false|clean:true)
            requirements=(
                'development-stop|1|^podman stop jailbox-project-[[:xdigit:]]+$'
                'proxy-stop|1|^podman stop .*-proxy$'
                'development-removal|1|^podman rm jailbox-project-[[:xdigit:]]+$'
                'proxy-removal|1|^podman rm .*-proxy$'
                'internal-network-removal|1|^podman network rm .*-net-internal$'
                'external-network-removal|1|^podman network rm .*-net-external$'
            )
            if [[ "$contract" = clean || "$policy" = true ]]; then
                requirements+=('home-removal|1|^podman volume rm .*-home$')
            fi
            if [[ "$contract" = clean ]]; then
                requirements+=(
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
