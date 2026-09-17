#!/bin/bash
# Reconstruction owns exact fixture resources, independently of stop/clean's
# behavior under test. Keep derived images available to Podman's build cache.
reset_fixture() {
    local name
    unset LIFECYCLE_EVENTS LIFECYCLE_FAULT_AT LIFECYCLE_FAULT_MODE LIFECYCLE_FAIL_SSH LIFECYCLE_FAIL_REMOVE
    unset LIFECYCLE_FAIL_HOME_INSPECT
    for name in "$PREFIX" "$PREFIX-proxy"; do
        if exists container "$name"; then podman rm -f "$name" >/dev/null; fi
    done
    for name in "$NETWORK" "$NETWORK-internal" "$NETWORK-external" "$EXTRA"; do
        if exists network "$name"; then podman network rm "$name" >/dev/null; fi
    done
    if exists volume "$HOME_VOLUME"; then podman volume rm "$HOME_VOLUME" >/dev/null; fi
    podman unshare rm -rf -- "$STATE"
    rm -f -- "$FIXTURE/saved-key"
    export JAILBOX_CONFIG_EPHEMERAL_HOME=false JAILBOX_CONFIG_EGRESS_ALLOW=""
    unset JAILBOX_CONFIG_MEMORY_LIMIT JAILBOX_CONFIG_EGRESS_ALLOW_0 JAILBOX_CONFIG_READONLY_PATHS_0
}
