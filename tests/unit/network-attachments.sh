#!/bin/bash
# Network identity representations used by older and newer Podman releases.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=host/network.sh
source "$ROOT/host/network.sh"
# shellcheck source=host/ssh.sh
source "$ROOT/host/ssh.sh"
# shellcheck source=host/container-runtime.sh
source "$ROOT/host/container-runtime.sh"

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

podman() {
    case "$1 $2 $5" in
        'network inspect {{.ID}}') echo "$TEST_NETWORK_ID" ;;
        'network inspect '*'.Created.UnixNano'*) echo "$network_original" ;;
        'container inspect {{.Created.UnixNano}}') echo 1770000000000000000 ;;
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
echo 'Network attachment identity tests passed'
