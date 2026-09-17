#!/bin/bash
# Fake Podman over a directory of resource files named <kind>.<name>, each
# holding LABEL=VALUE lines. Absent files are absent resources.
state="$FAKE_PODMAN_STATE"
file="$state/$1.$3"

case "$1 $2" in
    "network ls"|"volume ls")
        for resource in "$state/$1."*; do
            [[ -f "$resource" ]] || continue
            resource=${resource##*/}
            printf '%s\n' "${resource#*.}"
        done
        ;;
    "container exists"|"volume exists"|"network exists")
        [ -f "$file" ]
        ;;
    "container inspect"|"volume inspect"|"network inspect")
        [ -f "$file" ] || exit 1
        label=$(printf '%s' "$5" | sed -n 's/.*index [^ ]* "\([^"]*\)".*/\1/p')
        [ -n "$label" ] || exit 1
        sed -n "s|^$label=||p" "$file"
        ;;
    *) exit 1 ;;
esac
