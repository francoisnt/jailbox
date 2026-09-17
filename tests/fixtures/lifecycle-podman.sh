#!/bin/bash
state="$FAKE_PODMAN_STATE"

resource_file() {
    printf '%s/%s.%s\n' "$state" "$1" "$2"
}

case "$1 $2" in
    "network ls"|"volume ls")
        [ "${FAKE_PODMAN_EXISTS_ERROR_KIND:-}" != "$1" ] || exit 125
        for resource in "$state/$1."*; do
            [ -f "$resource" ] || continue
            resource=${resource##*/}
            printf '%s\n' "${resource#*.}"
        done
        ;;
    "container exists"|"volume exists"|"network exists"|"image exists")
        [ "${FAKE_PODMAN_EXISTS_ERROR_KIND:-}" != "$1" ] || exit 125
        if [ "${FAKE_PODMAN_RECHECK_ERROR:-}" = 1 ] && [ -f "$state/vanished" ]; then
            exit 125
        fi
        [ -f "$(resource_file "$1" "$3")" ]
        ;;
    "container inspect"|"volume inspect"|"network inspect")
        [ "${FAKE_PODMAN_INSPECT_ERROR_KIND:-}" != "$1" ] || exit 125
        file=$(resource_file "$1" "$3")
        [ -f "$file" ] || exit 1
        if [ "$1" = volume ]; then
            if [ "$5" = '{{.Mountpoint}}' ]; then
                printf '%s/home-contents\n' "$state"
                exit 0
            fi
            awk -F= '$1 == "jailbox.ephemeral-home" {
                if ($0 == "jailbox.ephemeral-home=true") print "true";
                else if ($0 == "jailbox.ephemeral-home=false") print "false";
                else print "corrupt";
            }' "$file"
        else
            cat "$file"
        fi
        ;;
    "volume create")
        [ "$3" = --label ] || exit 1
        printf '%s' "$4" > "$(resource_file volume "$5")"
        printf 'volume create %s\n' "$5" >> "$state/actions"
        ;;
    "volume rm"|"network rm"|"image rm")
        if [ "${FAKE_PODMAN_VANISH_NAME:-}" = "$3" ]; then
            rm -f "$(resource_file "$1" "$3")"
            touch "$state/vanished"
            exit 125
        fi
        [ "${FAKE_PODMAN_REMOVE_ERROR_NAME:-}" != "$3" ] || exit 125
        if [ "$1" = image ] && [ -f "$(resource_file image "${3%-dev}-image")" ]; then
            # A wrapper child prevents removing its sole-tagged dev parent.
            [ "${3%-dev}" = "$3" ] || exit 125
        fi
        file=$(resource_file "$1" "$3")
        [ -f "$file" ] || exit 1
        printf '%s rm %s\n' "$1" "$3" >> "$state/actions"
        rm -f "$file"
        ;;
    *)
        case "$1" in
            unshare) exit 0 ;;
            stop)
                [ -f "$(resource_file container "$2")" ] || exit 1
                printf 'container stop %s\n' "$2" >> "$state/actions"
                ;;
            rm)
                file=$(resource_file container "$2")
                [ "${FAKE_PODMAN_REMOVE_ERROR_NAME:-}" != "$2" ] || exit 125
                if [ "${FAKE_PODMAN_VANISH_NAME:-}" = "$2" ]; then
                    rm -f "$file"
                    touch "$state/vanished"
                    exit 125
                fi
                [ -f "$file" ] || exit 1
                printf 'container rm %s\n' "$2" >> "$state/actions"
                rm -f "$file"
                ;;
            *) exit 1 ;;
        esac
        ;;
esac
