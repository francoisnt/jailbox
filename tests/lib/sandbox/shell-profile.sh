#!/bin/bash
# Own the temporary login profile, preserving any image-provided customization.
set -euo pipefail
backup="$HOME/.jailbox-shell-profile-test"
case "$1" in
    install)
        mkdir -m 700 "$backup"
        if [[ -e "$HOME/.bash_profile" || -L "$HOME/.bash_profile" ]]; then
            mv "$HOME/.bash_profile" "$backup/profile"
        fi
        ;;
    restore)
        [[ -d "$backup" ]] || exit 1
        rm -f "$HOME/.bash_profile"
        if [[ -e "$backup/profile" || -L "$backup/profile" ]]; then
            mv "$backup/profile" "$HOME/.bash_profile"
        fi
        rmdir "$backup"
        ;;
    *) exit 2 ;;
esac
