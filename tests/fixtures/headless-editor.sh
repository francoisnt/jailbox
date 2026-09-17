#!/bin/bash
set -euo pipefail

container=""
user_data_dir=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--remote" ]]; then
        container="${arg#ssh-remote+}"
    elif [[ "$prev" == "--user-data-dir" ]]; then
        user_data_dir="$arg"
    elif [[ "$prev" == "-F" ]]; then
        echo "stub: unexpected SSH -F option passed to editor" >&2
        exit 1
    fi
    prev="$arg"
done

[[ -n "${JAILBOX_E2E_PROJECT:-}" ]] || { echo "stub: JAILBOX_E2E_PROJECT not set" >&2; exit 1; }
[[ "${JAILBOX_E2E_REJECT_EDITOR:-}" != "1" ]] || { echo "stub: editor must not be called by up" >&2; exit 1; }
[[ -n "$user_data_dir" ]] || { echo "stub: no --user-data-dir argument received" >&2; exit 1; }
[[ -f "$user_data_dir/User/settings.json" ]] || { echo "stub: user-data settings missing" >&2; exit 1; }
grep -Fq '"remote.SSH.configFile":' "$user_data_dir/User/settings.json" || {
    echo "stub: user-data settings missing remote.SSH.configFile" >&2
    exit 1
}
if [[ -z "$container" ]]; then
    echo "stub: no ssh-remote+<container> argument received" >&2
    exit 1
fi

echo "stub: editor called"
