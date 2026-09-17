#!/bin/bash
set -euo pipefail
case "$1" in
    absent)
        for file in "$HOME/.curlrc" "$HOME/.wgetrc"; do
            if [[ -f "$file" ]] && grep -Fqx '# >>> jailbox managed proxy >>>' "$file"; then
                exit 1
            fi
        done
        ;;
    curl)
        grep -Fqx '# >>> jailbox managed proxy >>>' "$HOME/.curlrc"
        grep -Fqx "proxy = \"$2\"" "$HOME/.curlrc"
        grep -Fqx '# <<< jailbox managed proxy <<<' "$HOME/.curlrc"
        ;;
    wget)
        grep -Fqx '# >>> jailbox managed proxy >>>' "$HOME/.wgetrc"
        grep -Fqx 'use_proxy = on' "$HOME/.wgetrc"
        grep -Fqx "http_proxy = $2" "$HOME/.wgetrc"
        grep -Fqx "https_proxy = $2" "$HOME/.wgetrc"
        grep -Fqx '# <<< jailbox managed proxy <<<' "$HOME/.wgetrc"
        ;;
    *) exit 2 ;;
esac
