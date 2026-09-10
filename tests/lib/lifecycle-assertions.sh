#!/bin/bash
# Normalize only allocation suffixes, retaining the operation and its operands.
# Preparation directory names vary between otherwise identical reconstructions.
lifecycle_event_identity() {
    sed -E 's/(\.ssh-generation\.)[[:alnum:]]+/\1ALLOCATED/g; s/(gitconfig\.tmp\.)[[:alnum:]]+/\1ALLOCATED/g'
}

lifecycle_same_fault_event() {
    local expected actual point="$3"
    [[ "$point" =~ ^[1-9][0-9]*$ ]] || return 1
    expected=$(sed -n "${point}p" "$1" | lifecycle_event_identity) || return 1
    actual=$(sed -n "${point}p" "$2" | lifecycle_event_identity) || return 1
    [[ -n "$expected" && "$expected" = "$actual" ]]
}

# Identity and state must occur in the same diagnostic record. Token boundaries
# prevent a proxy name or 'not-running' from satisfying the development record.
lifecycle_reports_state() {
    LC_ALL=C awk -v name="$2" -v state="$3" '
        { gsub(/[^[:alnum:]_-]+/, " "); named=0; observed=0
          for (i=1; i<=NF; i++) { if ($i == name) named=1; if ($i == state) observed=1 }
          if (named && observed) found=1 }
        END { exit !found }
    ' "$1"
}
