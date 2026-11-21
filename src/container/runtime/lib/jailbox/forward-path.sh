#!/bin/sh
# System login shells may reset PATH before loading /etc/profile.d.
_jailbox_commands=/run/jailbox-sshd/host-commands
if [ -d "$_jailbox_commands" ]; then
    PATH="$_jailbox_commands:${PATH#"$_jailbox_commands:"}"
    export PATH
fi
unset _jailbox_commands
