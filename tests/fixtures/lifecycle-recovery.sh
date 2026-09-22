#!/bin/bash
# Simulated resource operations for the real lifecycle row runner.
# shellcheck disable=SC2329 # These callbacks are invoked by the sourced runner.
set -euo pipefail
matrix_die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
matrix_case_begin() { CASE_KEY=$1; }
matrix_case_pass() { printf '%s\n' "$CASE_KEY" >> "$LOG/passed"; }
construct() {
    mkdir -p "$GENERATION" "$HOME_PATH"
    printf 'retained\n' > "$HOME_PATH/lifecycle-marker"
    printf 'false\n' > "$HOME_PATH/label"
    printf 'unrelated runtime content\n' > "$STATE/unrelated"
    touch "$FIXTURE/container" "$FIXTURE/network"
    # shellcheck disable=SC2034 # Consumed by the real cleanup assertion.
    STATE_UNRELATED=true
    DAMAGED=true
    if [[ ${RECOVERY_DAMAGE:-} = missing-initial-home ]]; then
        rm -rf -- "$HOME_PATH"
        # A previous case left plausible labels, but this fixture has no home.
        printf 'false\n' > "$LOG/home-labels-before"
    fi
}
exists() {
    case "$1:$2" in
        container:"$PREFIX") [[ -f "$FIXTURE/container" ]] ;;
        network:"$NETWORK") [[ -f "$FIXTURE/network" ]] ;;
        volume:"$HOME_VOLUME") [[ -d "$HOME_PATH" ]] ;;
        image:jailbox-test-debian) return 0 ;;
        *) return 1 ;;
    esac
}
podman() {
    case "$1:$2" in
        volume:inspect)
            if [[ "$*" = *Mountpoint* ]]; then printf '%s\n' "$HOME_PATH"
            else
                cat "$HOME_PATH/label"
                [[ ${RECOVERY_DAMAGE:-} != inspection ]] || return 125
            fi ;;
        unshare:*) shift; "$@" ;;
        *) matrix_die 'unexpected engine operation in recovery fixture' ;;
    esac
}
snapshot() { cat "$HOME_PATH/lifecycle-marker" "$HOME_PATH/label" "$STATE/unrelated"; }
image_snapshot() { printf 'retained-images\n'; }
cli() {
    printf '%s\n' "$1" >> "$LOG/commands"
    case "$1" in
        up)
            if [[ "$DAMAGED" = true ]]; then
                printf "run 'jailbox stop'\n" >&2
                return 1
            fi
            mkdir -p "$GENERATION"
            touch "$FIXTURE/container" "$FIXTURE/network"
            ;;
        stop)
            if [[ ${RECOVERY_DAMAGE:-} = missing-initial-home ]]; then
                mkdir -p "$HOME_PATH"
                printf 'retained\n' > "$HOME_PATH/lifecycle-marker"
                printf 'false\n' > "$HOME_PATH/label"
            fi
            rm -rf -- "$GENERATION"
            rm -f "$FIXTURE/container" "$FIXTURE/network"
            DAMAGED=false
            case "${RECOVERY_DAMAGE:-}" in
                container) touch "$FIXTURE/container" ;;
                home) printf 'lost\n' > "$HOME_PATH/lifecycle-marker" ;;
                labels) printf 'corrupt\n' > "$HOME_PATH/label" ;;
                unrelated) rm "$STATE/unrelated" ;;
                ssh-file:*) touch "$STATE/${RECOVERY_DAMAGE#*:}" ;;
                ssh-directory:*) mkdir "$STATE/${RECOVERY_DAMAGE#*:}" ;;
                ssh-link:*) ln -s "$STATE/missing-target" "$STATE/${RECOVERY_DAMAGE#*:}" ;;
            esac
            ;;
        *) matrix_die 'unexpected recovery command' ;;
    esac
}
# Invoke in the same shell so simulated resource effects survive.
test_log_capture() { local destination=$1; shift; "$@" > "$destination" 2>&1; }
assert_service() { [[ -e "$FIXTURE/container" && -d "$GENERATION" ]] || matrix_die 'relaunch omitted'; }
matrix_observe() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$LOG/observed"; }
