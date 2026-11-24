# Apply the latest available dependency updates locally.
update:
    #!/usr/bin/env bash
    set -euo pipefail
    updates=$(bash scripts/plan-updates.sh)
    if [[ -n "$updates" ]]; then
        mapfile -t update_lines <<< "$updates"
        exec bash scripts/apply-updates.sh "${update_lines[@]}"
    fi
