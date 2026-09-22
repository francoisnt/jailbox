#!/bin/bash
# Replace only external setup in a copied worker. Keep its real module loading,
# queue, dispatch, row runner, and contract validation.
# shellcheck disable=SC2034,SC2329 # State and callbacks consumed by the worker.
lifecycle_setup() {
    LOG=$2
    LIFECYCLE_SAMPLE_MODE=true
}

construct() {
    printf 'FAIL: unselected worker row constructed resources\n' >&2
    exit 1
}
