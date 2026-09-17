#!/bin/bash
# Shared lifecycle expectations, independent of engine inspection. Fields:
# key | network mode | stored home | requested home | up | status |
# attachment | recovery | retained home after recovery | status after stop
# Observers reuse these cases before lifecycle mutation and after recovery.
# An 'allow' verdict requires attachment health, not merely running inventory.

# Keep the catalog off stdin: callbacks launch SSH and other programs that may
# read stdin even when the remote command itself does not need input.
lifecycle_each_row() {
    local matrix_callback="$1" matrix_row_fd
    local -a matrix_row_fields=()
    exec {matrix_row_fd}< <(lifecycle_matrix_rows)
    while IFS='|' read -r -u "$matrix_row_fd" -a matrix_row_fields; do
        "$matrix_callback" "${matrix_row_fields[@]}"
    done
    exec {matrix_row_fd}<&-
}

lifecycle_matrix_rows() {
    local damage policy requested recovery retained status
    cat <<'ROWS'
absent|plain|none|false|success|absent|refuse|none|new|absent
running|plain|false|false|success|running|allow|none|keep|stopped
stopped|plain|false|false|success|stopped|refuse|none|keep|stopped
stopped-egress|egress|false|false|success|stopped|refuse|none|keep|stopped
networks-only|egress|false|false|success|stopped|refuse|none|keep|stopped
stopped-ephemeral|plain|true|true|success|stopped|refuse|none|keep|absent
mixed|egress|false|false|success|running|refuse|none|keep|stopped
missing-proxy|egress|false|false|success|running|refuse|none|keep|stopped
missing-dev|egress|false|false|success|stopped|refuse|none|keep|stopped
orphan-ssh|plain|false|false|refuse|stopped|refuse|stop|keep|stopped
partial-ssh|plain|none|false|refuse|absent|refuse|stop|new|absent
missing-network|plain|false|false|refuse|running|refuse|stop|keep|stopped
missing-internal|egress|false|false|refuse|running|refuse|stop|keep|stopped
missing-networks|egress|false|false|refuse|running|refuse|stop|keep|stopped
disconnected|egress|false|false|refuse|running|refuse|stop|keep|stopped
unexpected-attachment|egress|false|false|refuse|running|refuse|stop|keep|stopped
missing-digest|egress|false|false|refuse|running|refuse|stop|keep|stopped
inconsistent-digest|egress|false|false|refuse|running|refuse|stop|keep|stopped
mismatched-digest|plain|false|false|refuse|running|refuse|stop|keep|stopped
mode-and-digest|plain|false|true|refuse|running|refuse|clean|delete|stopped
mode-and-ssh|plain|false|true|refuse|running|refuse|clean|delete|stopped
corrupt-and-digest|plain|corrupt|false|refuse|stopped|refuse|clean|delete|stopped
collision-fallback|egress|false|false|success|running|allow|none|keep|stopped
managed-blocks|egress|false|false|success|running|refuse|none|keep|stopped
ROWS
    for policy in legacy false true empty corrupt newline; do
        for requested in false true; do
            recovery=clean; retained=delete; status=stopped
            case "$policy:$requested" in
                legacy:false|false:false) recovery=none; retained=keep ;;
                true:*) recovery=stop; retained=delete; status=absent ;;
            esac
            printf 'home-%s-%s|plain|%s|%s|%s|stopped|refuse|%s|%s|%s\n' \
                "$policy" "$requested" "$policy" "$requested" \
                "$([ "$recovery" = none ] && echo success || echo refuse)" \
                "$recovery" "$retained" "$status"
        done
    done
    for damage in missing symlink directory fifo owner mode server-pair client-pair authorized pin config parent-mode; do
        printf 'ssh-%s|plain|false|false|refuse|stopped|refuse|stop|keep|stopped\n' "$damage"
    done
}
