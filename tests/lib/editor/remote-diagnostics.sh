#!/bin/bash
# Diagnostics remain best effort so one missing artifact does not hide others.
set -uo pipefail
case "$1" in
    workspace)
        pwd
        ls -la /home/jailbox/project
        printf 'run_id_file='
        cat /home/jailbox/project/.jailbox-editor-run-id 2>/dev/null || true
        env | grep -E '^(HTTP|HTTPS|NO)_PROXY=' || true
        ;;
    proxy)
        for f in "$HOME/.curlrc" "$HOME/.wgetrc"; do
            echo --- "$f"
            if [[ -f "$f" ]]; then
                sed -n '/# >>> jailbox managed proxy >>>/,/# <<< jailbox managed proxy <<</p' "$f"
            else
                echo '(missing)'
            fi
        done
        ;;
    directories)
        for d in /home/jailbox/.vscode-server /home/jailbox/.vscodium-server; do
            echo --- "$d"
            if [[ -e "$d" ]]; then
                find "$d" -maxdepth 3 -print | sed -n '1,120p'
            else
                echo '(missing)'
            fi
        done
        ;;
    settings)
        for d in .vscodium-server .vscode-server; do
            f="$HOME/$d/data/Machine/settings.json"
            echo --- "$f"
            if [[ -f "$f" ]]; then cat "$f"; else echo '(missing)'; fi
        done
        ;;
    *) exit 2 ;;
esac
