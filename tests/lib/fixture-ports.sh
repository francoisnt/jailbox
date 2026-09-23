#!/bin/bash
# A stopped fixture's SSH port must not be borrowed for an outbound connection
# by another worker. Stay outside the kernel's ephemeral range and avoid ports
# already present in either IP socket table; never kill an unrelated listener.
test_fixture_port_available() {
    local port="$1" proc=${2:-/proc} lower upper extra hex
    local -a tables=("$proc/net/tcp")
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    ((port <= 65535)) || return 1
    read -r lower upper extra < "$proc/sys/net/ipv4/ip_local_port_range" || return 1
    [[ "$lower" =~ ^[1-9][0-9]{0,4}$ && "$upper" =~ ^[1-9][0-9]{0,4}$ && -z "$extra" ]] || return 1
    ((lower <= upper && upper <= 65535)) || return 1
    ((port < lower || port > upper)) || return 1
    if [[ -e "$proc/net/tcp6" ]]; then tables+=("$proc/net/tcp6"); fi
    hex=$(printf '%04X' "$port")
    awk -v port="$hex" '
        {n=split($2,address,":"); if (toupper(address[n])==port) occupied=1}
        END {exit occupied}
    ' "${tables[@]}"
}

# Claims survive stop/reopen cycles until the owning run ends. The optional
# availability callback also excludes host ports unsuitable for that runner.
test_fixture_project() {
    local prefix=$1 claims=$2 available=${3:-:} candidate hash offset port attempt
    for ((attempt=1; attempt<=100; attempt++)); do
        candidate=$(mktemp -d "$prefix.XXXXXX") || return 1
        hash=$(jailbox_project_hash_for_path "$candidate") || { rm -rf "$candidate"; return 1; }
        offset=$(jailbox_project_hash_port_offset "$hash") || { rm -rf "$candidate"; return 1; }
        port=$((49152 + offset))
        if "$available" "$port" && mkdir "$claims/$port" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        rm -rf "$candidate" || return 1
    done
    printf 'Could not reserve a fixture SSH port for %s\n' "$prefix" >&2
    return 1
}
