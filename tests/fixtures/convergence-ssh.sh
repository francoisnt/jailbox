#!/bin/bash
set -euo pipefail
command=${!#}
if [[ "$command" = '/usr/local/bin/jailbox-exec-argv '* ]]; then
    [[ " $* " = *' -T '* ]] || exit 99
    if [[ -n ${CONVERGENCE_EXEC_WAIT:-} ]]; then
        printf '%s\n' "$$" > "$CONVERGENCE_EXEC_WAIT"
        exec "$CONVERGENCE_REAL_SLEEP" 30
    fi
    exec bash "$CONVERGENCE_EXEC_HELPER" "${command#* }"
fi
# Model SSH eagerly reading input even for commands that do not need it.
if [[ ${CONVERGENCE_DRAIN_STDIN:-false} = true && "$command" != 'bash -s -- '* ]]; then cat >/dev/null; fi
if [[ -n ${CONVERGENCE_SSH_LOG:-} ]]; then printf "%s\n" "$command" >> "$CONVERGENCE_SSH_LOG"; fi
if [[ ${CONVERGENCE_SSH_FAILURE:-} == true ]]; then exit 255; fi
if [[ ${CONVERGENCE_UPSTREAM_FAILURE:-} == true && "$command" == *https://example.com/* ]]; then exit 6; fi
if [[ ${CONVERGENCE_DENIAL_TRANSPORT_FAILURE:-} == true && "$command" == *--write-out* ]]; then exit 6; fi
if [[ -n ${CONVERGENCE_CONNECT_FAILURES:-} && "$command" == *--write-out* ]]; then
    printf 'proxy-connect\n' >> "$CONVERGENCE_LOG"
    attempts=$(grep -c '^proxy-connect$' "$CONVERGENCE_LOG")
    if ((attempts <= CONVERGENCE_CONNECT_FAILURES)); then exit 28; fi
fi
case "$command" in
    'bash -s -- '*) cat >/dev/null; printf '%s\n' "${CONVERGENCE_SESSION_RESULT:-ok}" ;;
    *'--write-out'*) printf '%s' "${CONVERGENCE_DENIAL_CODE:-403}" ;;
    *'jailbox-manage-proxy enable'*|*'jailbox-manage-proxy disable'*) echo sync >> "$CONVERGENCE_LOG" ;;
    *'jailbox-manage-proxy check-enable'*|*'jailbox-manage-proxy check-disable'*)
        [[ ${CONVERGENCE_MANAGED_SETTINGS_FAILURE:-} != true ]] ;;
    *'sh -s'*) cat >/dev/null ;;
esac
