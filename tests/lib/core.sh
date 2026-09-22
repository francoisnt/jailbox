#!/bin/bash
# Source once per fixture scope, before assigning fixture state or stubs.
# The argument is the runtime root (src/ in a checkout, bundle root installed).
# Use the real entry boundary so tests do not maintain a second module order.
SCRIPT_DIR=$1
# shellcheck source=src/public-api.sh
source "$SCRIPT_DIR/public-api.sh"
# shellcheck source=src/host/api-support.sh
source "$SCRIPT_DIR/host/api-support.sh"
initialize_public_api_lookups
# shellcheck source=src/host/core/entry.sh
source "$SCRIPT_DIR/host/core/entry.sh"
