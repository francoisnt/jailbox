#!/bin/bash
state="$FAKE_PODMAN_STATE"

probe() {
    [ "${FAKE_PODMAN_PROBE_ERROR:-}" != "$1" ] || exit 125
    [ -f "$state/$1.$2" ]
}

remove() {
    [ -z "${FAKE_PODMAN_REMOVE_DELAY:-}" ] || sleep "$FAKE_PODMAN_REMOVE_DELAY"
    case " ${FAKE_PODMAN_UNREMOVABLE:-} " in
        *" $1.$2 "*) exit 0 ;;
    esac
    [ -f "$state/$1.$2" ] || exit 1
    printf '%s %s\n' "$1" "$2" >> "$state/removed"
    rm -f "$state/$1.$2"
}

case "$1 $2" in
    "container exists") probe container "$3" ;;
    "volume exists")    probe volume "$3" ;;
    "network exists")   probe network "$3" ;;
    "image exists")     probe image "$3" ;;
    "volume rm")        remove volume "$4" ;;
    "network rm")       remove network "$4" ;;
    *)
        case "$1" in
            rm)  remove container "$3" ;;
            rmi) remove image "$3" ;;
            *) exit 1 ;;
        esac
        ;;
esac
