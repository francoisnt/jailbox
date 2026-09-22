#!/bin/bash
# Network identity representations used by older and newer Podman releases.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/core/project/hash.sh
source "$ROOT/src/host/core/project/hash.sh"
# shellcheck source=src/host/core/resources/network.sh
source "$ROOT/src/host/core/resources/network.sh"
# shellcheck source=src/host/core/commands/up.sh
source "$ROOT/src/host/core/commands/up.sh"
# shellcheck source=src/host/core/resources/proxy.sh
source "$ROOT/src/host/core/resources/proxy.sh"
# shellcheck source=src/host/core/resources/ssh.sh
source "$ROOT/src/host/core/resources/ssh.sh"
# shellcheck source=src/host/core/resources/container.sh
source "$ROOT/src/host/core/resources/container.sh"
# shellcheck source=src/host/core/commands/status.sh
source "$ROOT/src/host/core/commands/status.sh"
# shellcheck source=src/host/core/resources/inventory.sh
source "$ROOT/src/host/core/resources/inventory.sh"
# shellcheck source=src/host/core/resources/home.sh
source "$ROOT/src/host/core/resources/home.sh"
# shellcheck source=src/host/core/commands/stop.sh
source "$ROOT/src/host/core/commands/stop.sh"
# shellcheck source=src/host/core/resources/runtime-files.sh
source "$ROOT/src/host/core/resources/runtime-files.sh"
# shellcheck source=src/host/core/commands/clean.sh
source "$ROOT/src/host/core/commands/clean.sh"
# shellcheck source=src/host/core/commands/up.sh
source "$ROOT/src/host/core/commands/up.sh"
# shellcheck source=src/host/core/checks/compatibility.sh
source "$ROOT/src/host/core/checks/compatibility.sh"

die() { echo "$*" >&2; exit 1; }
refuse_sandbox() { die "$*"; }
PROXY_NAME=test-proxy
NETWORK_STATE[selected_network]=test-network
TEST_NETWORK_ID=$(printf '%064d' 3)
TEST_ATTACHMENT_ID=$TEST_NETWORK_ID
attachment_present=true
attachment_count=true
network_original=true
running=true
proxy_address=true
TEST_CREATED=1770000000000000000
inspect_failure=false

podman() {
    [[ "$inspect_failure" = false ]] || return 125
    if [[ "$1 $2" = 'container inspect' && "$5" = *'{{printf "|"}}'* ]]; then
        local identity=false stopped=true template="$5" predicate value
        if [[ "$TEST_ATTACHMENT_ID" = "$TEST_NETWORK_ID" || "$TEST_ATTACHMENT_ID" = test-network || -z "$TEST_ATTACHMENT_ID" ]]; then identity=true; fi
        if [[ -z "$TEST_ATTACHMENT_ID" && "$running" = true ]]; then stopped=false; fi
        while [[ "$template" = *'{{printf "|"}}'* ]]; do
            predicate=${template%%'{{printf "|"}}'*}
            template=${template#*'{{printf "|"}}'}
            case "$predicate" in
                *'(len .NetworkSettings.Networks)'*) value=$attachment_count ;;
                *'.IPAddress'*) value=$proxy_address ;;
                *'or (eq .NetworkID'*) value=$identity ;;
                *'or (ne .NetworkID'*) value=$stopped ;;
                *) value=$attachment_present ;;
            esac
            printf '%s|' "$value"
        done
        printf '\n'
        return
    fi
    case "$1 $2 $5" in
        'network inspect {{.ID}} {{le .Created.UnixNano '*) printf '%s %s\n' "$TEST_NETWORK_ID" "$network_original" ;;
        'network inspect {{.ID}}') echo "$TEST_NETWORK_ID" ;;
        'network inspect '*'.Created.UnixNano'*) echo "$network_original" ;;
        'container inspect {{.Created.UnixNano}}') echo "$TEST_CREATED" ;;
        'container inspect '*'.NetworkID'*) printf '%s\n' "$TEST_ATTACHMENT_ID" ;;
        'container inspect {{not .State.Running}}')
            if [ "$running" = true ]; then echo false; else echo true; fi ;;
        'container inspect '*'(len .NetworkSettings.Networks)'*) echo "$attachment_count" ;;
        'container inspect '*'.NetworkSettings.Networks'*) echo "$attachment_present" ;;
        *) return 125 ;;
    esac
}

for running in true false; do
    for TEST_ATTACHMENT_ID in "$TEST_NETWORK_ID" test-network; do
        validate_container_networks test-dev
    done
done
TEST_ATTACHMENT_ID=
validate_container_networks test-dev

for scenario in running_empty wrong_id missing extra recreated; do
    if (
        TEST_ATTACHMENT_ID=$TEST_NETWORK_ID
        running=true
        case "$scenario" in
            running_empty) TEST_ATTACHMENT_ID= ;;
            wrong_id) TEST_ATTACHMENT_ID=$(printf '%064d' 4) ;;
            missing) attachment_present=false ;;
            extra) attachment_count=false ;;
            recreated) TEST_ATTACHMENT_ID=test-network; network_original=false ;;
        esac
        validate_container_networks test-dev
    ) >/dev/null 2>&1; then
        echo "FAIL: accepted $scenario network attachment" >&2
        exit 1
    fi
done
NETWORK_NAME='test'
NETWORK_STATE[proxy_url]=http://10.0.0.2:8888
TEST_ATTACHMENT_ID=$TEST_NETWORK_ID
validate_container_networks "$PROXY_NAME"
for scenario in proxy_address invalid_created inspect_failure; do
    if (
        case "$scenario" in
            proxy_address) proxy_address=false ;;
            invalid_created) TEST_CREATED='invalid' ;;
            inspect_failure) inspect_failure=true ;;
        esac
        validate_container_networks "$PROXY_NAME"
    ) >/dev/null 2>&1; then
        echo "FAIL: accepted $scenario" >&2
        exit 1
    fi
done
echo 'Network attachment identity tests passed'
