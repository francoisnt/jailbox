#!/bin/bash
# Independently maintained coverage floors for the seven healthy fault fixtures.
# These describe operation roles, not a total derived from the current trace.
# New operations are still swept automatically. Removing or replacing a required
# operation needs an explicit review of this contract, even if launch still works.
lifecycle_require_fault_coverage() {
    local trace="$1" command="$2" policy="$3" requirement minimum pattern count
    local -a requirements=()
    case "$command:$policy" in
        up:false|up:none|up:new-ephemeral)
            requirements=(
                'internal-network|1|^podman network create .* [^ ]+-net-internal$'
                'external-network|1|^podman network create .* [^ ]+-net-external$'
                'proxy-container|1|^podman run .* --name [^ ]+-proxy '
                'development-container|1|^podman run .* --cidfile '
                'state-directories|4|^mkdir -p '
                'proxy-filter-permissions|1|^chmod 644 .*/tinyproxy-filter$'
                'proxy-config-permissions|1|^chmod 644 .*/tinyproxy[.]conf$'
                'gitconfig-removal|1|^rm .*/gitconfig$'
                'gitconfig-allocation|1|^mktemp .*/gitconfig[.]tmp[.]'
                'gitconfig-staging-permissions|1|^chmod 600 .*/gitconfig[.]tmp[.]'
                'gitconfig-publication|1|^mv .*/gitconfig[.]tmp[.].* /.*gitconfig$'
                'gitconfig-permissions|1|^chmod 600 .*/gitconfig$'
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
        stop:false|stop:true|--clean:false|--clean:true)
            requirements=(
                'development-stop|1|^podman stop jailbox-project-[[:xdigit:]]+$'
                'proxy-stop|1|^podman stop .*-proxy$'
                'development-removal|1|^podman rm jailbox-project-[[:xdigit:]]+$'
                'proxy-removal|1|^podman rm .*-proxy$'
                'internal-network-removal|1|^podman network rm .*-net-internal$'
                'external-network-removal|1|^podman network rm .*-net-external$'
            )
            if [[ "$command" = --clean || "$policy" = true ]]; then
                requirements+=('home-removal|1|^podman volume rm .*-home$')
            fi
            if [[ "$command" = --clean ]]; then
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
    for requirement in "${requirements[@]}"; do
        IFS='|' read -r requirement minimum pattern <<< "$requirement"
        count=$(LC_ALL=C grep -Ec -- "$pattern" "$trace") || {
            [[ "$count" = 0 ]] || return 1
        }
        if ((count < minimum)); then
            printf 'Missing fault coverage [%s:%s]: %s (need %s, recorded %s)\n' \
                "$command" "$policy" "$requirement" "$minimum" "$count" >&2
            return 1
        fi
    done
}

# Normalize only allocation suffixes, retaining the operation and its operands.
# Preparation directory names vary between otherwise identical reconstructions.
lifecycle_event_identity() {
    sed -E 's/(\.ssh-generation\.)[[:alnum:]]+/\1ALLOCATED/g; s/(gitconfig\.tmp\.)[[:alnum:]]+/\1ALLOCATED/g'
}

lifecycle_same_fault_event() {
    local expected actual point="$3"
    [[ "$point" =~ ^[1-9][0-9]*$ ]] || return 1
    expected=$(sed -n "${point}p" "$1" | lifecycle_event_identity) || return 1
    actual=$(sed -n "${point}p" "$2" | lifecycle_event_identity) || return 1
    [[ -n "$expected" && "$expected" = "$actual" ]]
}

# Identity and state must occur in the same diagnostic record. Token boundaries
# prevent a proxy name or 'not-running' from satisfying the development record.
lifecycle_reports_state() {
    LC_ALL=C awk -v name="$2" -v state="$3" '
        { gsub(/[^[:alnum:]_-]+/, " "); named=0; observed=0
          for (i=1; i<=NF; i++) { if ($i == name) named=1; if ($i == state) observed=1 }
          if (named && observed) found=1 }
        END { exit !found }
    ' "$1"
}
