#!/bin/bash
# Shared discovery for lint, portable syntax checks, and release packaging.
container_bash=()
container_sh=()

collect_container_shells() {
    local root="$1" script interpreter files
    container_bash=()
    container_sh=()
    files=$(find "$root/container" -type f -print) || return 1
    files=$(LC_ALL=C sort <<< "$files") || return 1
    while IFS= read -r script; do
        [[ -n "$script" ]] || continue
        interpreter=""
        # read supplies the final line even when EOF precedes a newline.
        IFS= read -r interpreter < "$script" || true
        case "$interpreter" in
            '#!/bin/bash'|'#!/usr/bin/env bash') container_bash+=("$script") ;;
            '#!/bin/sh'|'#!/usr/bin/env sh') container_sh+=("$script") ;;
            *)
                if [[ "$script" = *.sh || "$script" = "$root/container/runtime/bin/"* ]]; then
                    printf 'Error: unsupported shell shebang in %s\n' "$script" >&2
                    return 1
                fi
                ;;
        esac
    done <<< "$files"
}

check_container_syntax() {
    local script
    collect_container_shells "$1" || return 1
    for script in "${container_bash[@]}"; do
        bash -n "$script" || return 1
    done
    for script in "${container_sh[@]}"; do
        sh -n "$script" || return 1
    done
}
