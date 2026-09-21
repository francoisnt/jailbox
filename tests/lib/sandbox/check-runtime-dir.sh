#!/bin/bash
set -e

# A negated command is exempt from set -e, so every refusal exits
# explicitly. Writability is proved by writing: test -w answers from
# mode bits in some shells and calls a read-only mount writable.
refute() { if "$@"; then exit 1; fi; }
# true, not :, so a refused redirection fails the command instead of
# aborting the shell the way a failed special-builtin redirect does.
refute_write() { if true 2>/dev/null > "$1"; then exit 1; fi; }
refute_append() { if true 2>/dev/null >> "$1"; then exit 1; fi; }

test -d /run/jailbox-sshd
test -x /usr/local/bin/jailbox-exec-argv
test -x /usr/local/bin/jailbox-write-editor-settings
test -r /usr/local/lib/jailbox/authentication-mount.awk
test -r /usr/local/lib/jailbox/readonly-mount.awk
test -r /usr/local/lib/jailbox/process-hardening.awk
test "$(stat -c %a /usr/local/lib/jailbox)" = 755
for helper in /usr/local/lib/jailbox/*.awk; do
    test "$(stat -c %a "$helper")" = 644
done
for helper in /usr/local/bin/jailbox-*; do
    test -x "$helper"
    test "$(stat -c %a "$helper")" = 755
done
test "$(/usr/local/bin/jailbox-exec-argv cHdkAA==)" = /home/jailbox/project
refute /usr/local/bin/jailbox-exec-argv Y2F0
refute_write /run/jailbox-sshd/probe
refute_append /run/jailbox-sshd/authorized_keys
test -s /run/jailbox-sshd/session.conf
refute_append /run/jailbox-sshd/session.conf
refute_append /run/jailbox-sshd/ssh_host_ed25519_key
refute test -e /run/jailbox-sshd/key
refute test -e /run/jailbox-sshd/known_hosts
refute test -e /run/jailbox-sshd/ssh_config
true > /run/daemon-state-probe && rm -f /run/daemon-state-probe
daemon_metadata=$(
    stat -c "%u:%g:%a" /run 2>/dev/null ||
    stat -f "%u:%g:%Lp" /run
)
test "$daemon_metadata" = "$(id -u):$(id -g):700"
test -f /run/sshd.pid
refute test -e /etc/ssh/jailbox_authorized_keys.source

runtime_uid=$(
    stat -c "%u" /run/jailbox-sshd 2>/dev/null ||
    stat -f "%u" /run/jailbox-sshd
)
test "$runtime_uid" = "$(id -u)"

runtime_mode=$(
    stat -c "%a" /run/jailbox-sshd 2>/dev/null ||
    stat -f "%Lp" /run/jailbox-sshd
)
case "$runtime_mode" in
    700|1700) ;;
    *) exit 1 ;;
esac
