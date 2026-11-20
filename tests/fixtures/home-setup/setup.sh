#!/bin/sh
set -eu
test "$#" = 0
test "$(id -un)" = jailbox
test "$HOME" = /home/jailbox
test "$PWD" = /home/jailbox/project
test -n "${HTTPS_PROXY:-}"
test -z "${JAILBOX_TEST_SETUP_HOST_SESSION:-}"
for script in ./setup-home.sh ./setup-input.sh; do
    if (printf 'must remain read-only\n' >> "$script") 2>/dev/null; then
        exit 87
    fi
done
umask 077
cat > "$HOME/setup-input"
