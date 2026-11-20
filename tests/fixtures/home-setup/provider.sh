#!/bin/sh
set -eu
test "$#" = 0
test -f ./setup-home.sh
test "${JAILBOX_TEST_SETUP_HOST_SESSION:-}" = host-only
printf 'test-home-setup-private-input\000\377\n\n'
