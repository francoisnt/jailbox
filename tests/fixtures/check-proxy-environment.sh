#!/bin/bash
# shellcheck disable=SC2154 # These values must come from the SSH session.
set -euo pipefail
[[ "$HTTP_PROXY" = "$1" && "$HTTPS_PROXY" = "$1" &&
   "$http_proxy" = "$1" && "$https_proxy" = "$1" &&
   -n "$NO_PROXY" && "$NO_PROXY" = "$no_proxy" ]] &&
! shopt -q login_shell
