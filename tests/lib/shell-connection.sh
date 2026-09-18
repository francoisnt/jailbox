#!/bin/bash
# Read the shell test's expected proxy environment from the public interface.
shell_connection_proxy() {
    local project="$1" cli="$2" output="$3" record name value proxy="" index=0
    local -a required=(ssh_config ssh_host remote_path project_id proxy_url)
    local -A seen=()
    # Check the producer separately: even plausible output from a failed CLI
    # must not become an expectation. Retain the byte stream for test diagnosis.
    (cd "$project" && "$cli" connection-info) > "$output" || return 1
    while :; do
        record=""
        if ! IFS= read -r -d '' record; then
            [[ -z "$record" ]] || { echo 'unterminated connection record' >&2; return 1; }
            break
        fi
        [[ "$record" = *$'\t'* ]] || { echo 'connection record has no separator' >&2; return 1; }
        name=${record%%$'\t'*}
        value=${record#*$'\t'}
        [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || { echo 'invalid connection field name' >&2; return 1; }
        [[ ! -v seen[$name] ]] || { echo 'duplicate connection field' >&2; return 1; }
        seen["$name"]=1
        if ((index < ${#required[@]})); then
            [[ "$name" = "${required[index]}" ]] || { echo 'missing or reordered connection field' >&2; return 1; }
        fi
        # Validate the consumed value using configure_proxy_env's grammar.
        # Unknown trailing fields remain opaque, including tabs and newlines.
        if [[ "$name" = proxy_url ]]; then
            [[ -z "$value" || "$value" =~ ^http://([0-9]{1,3}\.){3}[0-9]{1,3}:8888$ ]] || {
                echo 'invalid connection proxy URL' >&2
                return 1
            }
            proxy=$value
        fi
        index=$((index + 1))
    done < "$output"
    ((index >= ${#required[@]})) || { echo 'missing connection field' >&2; return 1; }
    printf '%s' "$proxy"
}
