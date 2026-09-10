#!/bin/bash
# Test-only PATH wrapper. All ordinary calls reach the real executable. Only
# project-scoped persistent operations count as fault points; no production
# configuration or host module has an injection switch.
set -euo pipefail
name=${0##*/}
real="$LIFECYCLE_REAL_BIN/$name"
mutation=false
case "$name" in
    podman)
        # Fail only retention inspection; existence and unrelated inspections
        # still reach the engine so operational failure cannot masquerade as absence.
        if [[ ${1:-} = volume && ${2:-} = inspect &&
            ${3:-} = "${LIFECYCLE_FAIL_HOME_INSPECT:-}" && "$*" = *jailbox.ephemeral-home* ]]; then
            exit 125
        fi
        case "${1:-} ${2:-}" in
            'network create'|'network rm'|'volume create'|'volume rm'|'image rm'|'unshare chown') mutation=true ;;
            *)
                case "${1:-}" in
                    start|stop|rm) mutation=true ;;
                    run)
                        case " $* " in *' --rm '*) ;; *) mutation=true ;; esac
                        ;;
                esac ;;
        esac
        ;;
    ssh-keygen)
        case " $* " in *"$XDG_STATE_HOME/"*' -N '*) mutation=true ;; esac
        ;;
    mkdir|cp|chmod|mv|rm|mktemp)
        case " $* " in *"$XDG_STATE_HOME/"*) mutation=true ;; esac
        ;;
    ssh)
        case " $* " in *'jailbox-manage-proxy enable'*|*'jailbox-manage-proxy disable'*) mutation=true ;; esac
        if [[ ${LIFECYCLE_FAIL_SSH:-false} = true ]]; then exit 255; fi
        ;;
esac
selected=false
if [[ "$mutation" = true && -n ${LIFECYCLE_EVENTS:-} ]]; then
    count=0
    [[ ! -f "$LIFECYCLE_EVENTS" ]] || count=$(wc -l < "$LIFECYCLE_EVENTS")
    count=$((count + 1))
    {
        printf '%s' "$name"
        printf ' %q' "$@"
        printf '\n'
    } >> "$LIFECYCLE_EVENTS"
    [[ "$count" != "${LIFECYCLE_FAULT_AT:-0}" ]] || selected=true
fi
# Simulate a refused removal, recording the attempt above without deleting the
# real container. Rollback must retain its dependencies and authentication.
if [[ "$name" = podman && ${1:-} = rm && ${LIFECYCLE_FAIL_REMOVE:-false} = true ]]; then
    exit 125
fi
if [[ "$mutation" != true || -z ${LIFECYCLE_EVENTS:-} ]]; then exec "$real" "$@"; fi
if [[ "$selected" = true && ${LIFECYCLE_FAULT_MODE:-} = before ]]; then exit 125; fi
"$real" "$@"
if [[ "$selected" = true ]]; then
    case "${LIFECYCLE_FAULT_MODE:-}" in
        after) exit 125 ;;
        barrier)
            # FIFO rendezvous, no timing-based interruption. The controller
            # kills the CLI while this child is paused after the real mutation.
            printf 'ready\n' > "$LIFECYCLE_READY"
            IFS= read -r release < "$LIFECYCLE_RELEASE"
            [[ "$release" = release ]] || exit 125
            exit 125
            ;;
    esac
fi
