#!/bin/bash
# Runtime and security assertions used by integration tests.
#
# This file is sourced by tests/integration/wrapper-images.sh so these checks run
# during the existing integration container launch instead of starting another
# Podman-heavy suite.

runtime_file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1"
    else
        cksum "$1"
    fi
}

runtime_file_metadata() {
    stat -c '%a:%s:%Y:%i' "$1" 2>/dev/null ||
        stat -f '%Lp:%z:%m:%i' "$1"
}

assert_runtime_dir_valid() {
    local config="$1" desc="$2"

    if ssh_run "$config" 'bash -s' < "$JAILBOX_DIR/tests/lib/sandbox/check-runtime-dir.sh" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

assert_bad_runtime_dir_fails() {
    local wrapper_image="$1" ssh_dir="$2" ctr_name="$3" desc="$4"
    local bad_ctr bad_home bad_runtime bad_uid logs rc

    bad_ctr="${ctr_name}-bad-runtime"
    bad_home=$(mktemp -d)
    bad_runtime=$(mktemp -d)
    bad_uid=$(( $(id -u) + 10000 ))
    ssh-keygen -t ed25519 -f "$bad_runtime/ssh_host_ed25519_key" -N "" -q
    cp "$ssh_dir/key.pub" "$bad_runtime/authorized_keys"
    chmod 600 "$bad_runtime/authorized_keys"
    logs=""
    rc=0

    podman rm -f "$bad_ctr" >/dev/null 2>&1 || true

    if podman run -d \
        --name "$bad_ctr" \
        --replace \
        --userns=keep-id \
        --env JAILBOX_SSH_PROXY_URL= \
        --user "${bad_uid}:${bad_uid}" \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --tmpfs /run:rw,size=64m \
        -v "${bad_home}:/home/jailbox:Z" \
        -v "${bad_runtime}:/run/jailbox-sshd:ro,Z" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        "$wrapper_image" >/dev/null; then
        podman wait "$bad_ctr" >/dev/null 2>&1 || true
        rc=$(podman inspect "$bad_ctr" --format '{{.State.ExitCode}}' 2>/dev/null || echo 0)
        logs=$(podman logs "$bad_ctr" 2>&1 || true)
    else
        rc=1
        logs=$(podman logs "$bad_ctr" 2>&1 || true)
    fi

    podman rm -f "$bad_ctr" >/dev/null 2>&1 || true
    rm -rf "$bad_home" "$bad_runtime"

    if [ "$rc" -ne 0 ] && grep -Fq "sshd runtime directory" <<< "$logs"; then
        pass "$desc"
    else
        fail "$desc"
        echo "  Bad runtime diagnostic (exit $rc):" >&2
        printf '%s\n' "$logs" | sed 's/^/    /' >&2
    fi
}

assert_host_container_sockets_absent() {
    local config="$1"

    assert_ssh "$config" "no docker socket" "! test -S /var/run/docker.sock"
    assert_ssh "$config" "no podman socket" "! test -S /run/podman/podman.sock"
}

assert_rootfs_read_only() {
    local config="$1" desc="$2"

    if ssh_run "$config" "touch /etc/.integration-test" 2>/dev/null; then
        fail "$desc (expected failure, got success)"
    else
        pass "$desc"
    fi
}

assert_zero_effective_capabilities() {
    local config="$1"

    assert_ssh "$config" "container starts with zero effective capabilities" \
        "awk '/^CapEff:/ { exit (\$2 == \"0000000000000000\" ? 0 : 1) }' /proc/1/status"
}

# Request forwarding explicitly with a real local agent: absence of an agent
# socket must result from server policy, not from a client default or no agent.
assert_ssh_forwarding_disabled() (
    local config=$1 container=$2 agent_dir agent_pid="" attempt policy
    agent_dir=$(mktemp -d) || return 1
    # shellcheck disable=SC2329 # Invoked by this subshell's EXIT trap.
    cleanup_forwarding_agent() {
        local status=$?
        if [[ -n "$agent_pid" ]]; then
            kill "$agent_pid" 2>/dev/null || true
            wait "$agent_pid" 2>/dev/null || true
        fi
        rm -rf -- "$agent_dir"
        exit "$status"
    }
    trap cleanup_forwarding_agent EXIT
    trap 'exit 1' HUP INT TERM
    ssh-agent -D -a "$agent_dir/socket" > "$agent_dir/log" 2>&1 &
    agent_pid=$!
    for ((attempt=0; attempt<50; attempt++)); do
        [[ ! -S "$agent_dir/socket" ]] || break
        kill -0 "$agent_pid" 2>/dev/null || { cat "$agent_dir/log" >&2; return 1; }
        sleep 0.1
    done
    [[ -S "$agent_dir/socket" ]] || return 1
    SSH_AUTH_SOCK="$agent_dir/socket" ssh -A -F "$config" -o ConnectTimeout=3 \
        jailbox-test 'test -z "${SSH_AUTH_SOCK:-}"' || return 1
    policy=$(podman exec "$container" sshd -T -f /etc/ssh/jailbox_sshd_config) || return 1
    grep -Fxq 'allowagentforwarding no' <<< "$policy" || return 1
    grep -Fxq 'x11forwarding no' <<< "$policy"
)

# host/core/resources/images.sh validation probes execute the dev image (including its
# entrypoint) before any jailbox runtime hardening applies, so podman_probe
# must supply its own constraints: no network and no capabilities.
# Sourcing happens inside the command substitutions because resources/images.sh
# defines jailbox_install_cache_bust, which would otherwise shadow this
# harness's version of that helper.
assert_probe_hardening() {
    local image="$1"
    local interfaces capabilities

    interfaces=$(
        # shellcheck source=src/host/core/resources/images.sh
        source "$JAILBOX_DIR/src/host/core/resources/images.sh"
        # shellcheck source=src/host/core/commands/validate.sh
        source "$JAILBOX_DIR/src/host/core/commands/validate.sh"
        podman_probe "$image" /bin/sh -c 'ls /sys/class/net' 2>/dev/null || true
    )
    if [ "$interfaces" = "lo" ]; then
        pass "dev-image probe has no network interfaces"
    else
        fail "dev-image probe has no network interfaces (got: ${interfaces:-none})"
    fi

    capabilities=$(
        # shellcheck source=src/host/core/resources/images.sh
        source "$JAILBOX_DIR/src/host/core/resources/images.sh"
        # shellcheck source=src/host/core/commands/validate.sh
        source "$JAILBOX_DIR/src/host/core/commands/validate.sh"
        podman_probe "$image" /bin/sh -c 'grep ^CapEff: /proc/self/status' 2>/dev/null || true
    )
    case "$capabilities" in
        *0000000000000000)
            pass "dev-image probe has zero effective capabilities"
            ;;
        *)
            fail "dev-image probe has zero effective capabilities (got: ${capabilities:-none})"
            ;;
    esac
}

# Regression coverage for check_readonly_mounts itself, not just the mounts.
# Run the production check against a project that has correctly read-only file
# and directory paths, plus two decoys listed as protected but mounted writable
# (Dockerfile, .github/workflows), and require it to flag exactly the decoys.
assert_readonly_mount_validation() {
    local config="$1" project_dir="$2"
    local output before_hash after_hash before_stat after_stat status
    # Host validation resolves its shipped payload relative to the CLI root.
    local SCRIPT_DIR="$JAILBOX_DIR/src"

    # shellcheck source=src/host/core/resources/ssh.sh
    source "$JAILBOX_DIR/src/host/core/resources/ssh.sh"
    # shellcheck source=src/host/core/checks/attachment.sh
    source "$JAILBOX_DIR/src/host/core/checks/attachment.sh"
    # shellcheck source=src/host/core/resources/container.sh
    source "$JAILBOX_DIR/src/host/core/resources/container.sh"
    # shellcheck source=src/host/core/resources/proxy.sh
    source "$JAILBOX_DIR/src/host/core/resources/proxy.sh"
    # shellcheck source=src/host/core/resources/downloader.sh
    source "$JAILBOX_DIR/src/host/core/resources/downloader.sh"
    # shellcheck source=src/host/core/commands/connection-info.sh
    source "$JAILBOX_DIR/src/host/core/commands/connection-info.sh"
    # shellcheck source=src/host/core/checks/compatibility.sh
    source "$JAILBOX_DIR/src/host/core/checks/compatibility.sh"
    # shellcheck disable=SC2329 # Resource validators invoke this refusal callback.
    refuse_sandbox() { echo "$*" >&2; exit 1; }

    # Globals consumed by check_readonly_mounts. CONTAINER_NAME doubles as
    # the ssh host alias, which this harness names jailbox-test.
    SSH_CONFIG="$config"
    CONTAINER_NAME="jailbox-test"
    PROJECT_DIR="$project_dir"
    REMOTE_PATH="/home/jailbox/project"

    EFFECTIVE_READONLY_PATHS=("Containerfile" ".git/hooks")
    if output=$(check_readonly_mounts 2>&1); then
        pass "read-only validation passes for correctly mounted paths"
    else
        fail "read-only validation passes for correctly mounted paths"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi

    before_hash=$(runtime_file_digest "$project_dir/Dockerfile")
    before_stat=$(runtime_file_metadata "$project_dir/Dockerfile")
    EFFECTIVE_READONLY_PATHS=("Containerfile" ".git/hooks" "Dockerfile" ".github/workflows")
    status=0
    output=$(check_readonly_mounts 2>&1) || status=$?
    after_hash=$(runtime_file_digest "$project_dir/Dockerfile")
    after_stat=$(runtime_file_metadata "$project_dir/Dockerfile")

    if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -q "read-only mount.*Dockerfile"; then
        pass "read-only validation flags writable file"
    else
        fail "read-only validation flags writable file"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi
    if [ "$before_hash" = "$after_hash" ] && [ "$before_stat" = "$after_stat" ] && [ ! -L "$project_dir/Dockerfile" ]; then
        pass "regular-file validation leaves bytes, metadata, and link type unchanged"
    else
        fail "regular-file validation leaves bytes, metadata, and link type unchanged"
    fi

    EFFECTIVE_READONLY_PATHS=(".github/workflows")
    status=0
    output=$(check_readonly_mounts 2>&1) || status=$?
    if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -q "read-only mount.*.github/workflows"; then
        pass "read-only validation flags writable directory"
    else
        fail "read-only validation flags writable directory"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi

}

start_runtime_fixture() {
    local ctr="$1" config="$2" port output attempt
    port=$(awk '/^[[:space:]]*Port / {print $2}' "$config")
    for ((attempt = 1; attempt <= 10; attempt++)); do
        if output=$(podman start "$ctr" 2>&1); then
            return 0
        fi
        # Rootless networking may outlive podman stop briefly. Retry only the
        # observed pasta bind race, using the actual bind result as evidence.
        # Other startup errors must remain visible immediately.
        if [[ "$output" != *'pasta failed'* ||
            "$output" != *"Failed to bind port $port (Address already in use)"* ]]; then
            break
        fi
        [[ "$attempt" -lt 10 ]] || break
        if [[ "$attempt" = 1 ]]; then
            printf '  Waiting for rootless networking to release port %s...\n' "$port"
        fi
        sleep 1
    done
    fail "could not restart fixture '$ctr' on port $port"
    printf '%s\n' "$output" >&2
    echo 'Check for an overlapping test run or a lingering listener; no unrelated process was stopped.' >&2
    return 1
}

assert_generation_restart() {
    local ctr="$1" config="$2" ssh_dir="$3" runtime_dir="$4"
    local before after exit_code
    before=$(for file in "$runtime_dir"/* "$ssh_dir/key" "$ssh_dir/known_hosts" "$config"; do runtime_file_digest "$file"; done)
    podman stop "$ctr" >/dev/null || { fail 'stop before generation restart'; return 1; }
    start_runtime_fixture "$ctr" "$config" || return 1
    if wait_for_ssh "$config"; then
        after=$(for file in "$runtime_dir"/* "$ssh_dir/key" "$ssh_dir/known_hosts" "$config"; do runtime_file_digest "$file"; done)
        assert_eq 'restart preserves every authentication/config byte' "$before" "$after"
    else
        fail 'same generation restarts with strict pinned authentication'
    fi

    cp "$ssh_dir/known_hosts" "$ssh_dir/saved-pin"
    ssh-keygen -t ed25519 -f "$ssh_dir/wrong-server" -N '' -q
    printf '[localhost]:%s %s\n' "$(awk '/^[[:space:]]*Port / {print $2}' "$config")" \
        "$(cat "$ssh_dir/wrong-server.pub")" > "$ssh_dir/known_hosts"
    if ssh_run "$config" true >/dev/null 2>&1; then
        fail 'wrong pinned server key refuses connection'
    else
        pass 'wrong pinned server key refuses connection'
    fi
    cp "$ssh_dir/saved-pin" "$ssh_dir/known_hosts"

    podman stop "$ctr" >/dev/null || { fail 'stop before exposed-key test'; return 1; }
    chmod 644 "$runtime_dir/ssh_host_ed25519_key"
    start_runtime_fixture "$ctr" "$config" || return 1
    podman wait "$ctr" >/dev/null
    exit_code=$(podman inspect "$ctr" --format '{{.State.ExitCode}}')
    if [ "$exit_code" -ne 0 ] && [ "$(runtime_file_metadata "$runtime_dir/ssh_host_ed25519_key" | cut -d: -f1)" = 644 ]; then
        pass 'startup refuses exposed server key without repairing permissions'
    else
        fail 'startup refuses exposed server key without repairing permissions'
    fi
    chmod 600 "$runtime_dir/ssh_host_ed25519_key"
    start_runtime_fixture "$ctr" "$config" || return 1
    wait_for_ssh "$config" || { fail 'restored fixture restarts'; return 1; }
}

# Real kernel mount enforcement: nested RW lane over RO base, then RO children.
assert_writable_lanes() (
    local image="$1" managed_id="$2" project probe_container built_image=''
    project=$(mktemp -d) || return 1
    probe_container="jailbox-writable-${project##*/}"
    # shellcheck disable=SC2329 # Invoked by the subshell EXIT trap.
    cleanup_writable_fixture() {
        podman rm -f --ignore "$probe_container" >/dev/null || return 1
        if [[ -n "$built_image" ]]; then podman image rm --ignore "$built_image" >/dev/null || return 1; fi
        rm -rf -- "$project"
    }
    trap cleanup_writable_fixture EXIT
    trap 'exit 1' HUP INT TERM
    mkdir -p "$project/lane/protected" || return 1
    printf original > "$project/single" || return 1
    printf protected > "$project/lane/policy" || return 1
    git -C "$project" init -q || return 1
    chmod 755 "$project" "$project/lane" "$project/lane/protected" "$project/.git/hooks" || return 1
    chmod 644 "$project/single" "$project/lane/policy" "$project/.git/config" || return 1
    if podman run --name "$probe_container" --rm -i --network none --read-only \
        --userns="keep-id:uid=$managed_id,gid=$managed_id" --user "$managed_id:$managed_id" \
        --cap-drop=ALL --security-opt=no-new-privileges --entrypoint bash \
        -v "$project:/project:Z,ro,rprivate" \
        -v "$project/lane:/project/lane:Z,rw,rprivate" \
        -v "$project/single:/project/single:Z,rw,rprivate" \
        -v "$project/.git:/project/.git:Z,rw,rprivate" \
        -v "$project/lane/protected:/project/lane/protected:Z,ro,rprivate" \
        -v "$project/lane/policy:/project/lane/policy:Z,ro,rprivate" \
        -v "$project/.git/config:/project/.git/config:Z,ro,rprivate" \
        -v "$project/.git/hooks:/project/.git/hooks:Z,ro,rprivate" \
        "$image" -s < "$JAILBOX_DIR/tests/lib/sandbox/check-writable-paths.sh"; then
        pass 'writable lanes, regular-file semantics, nested protection and Git commits'
    else
        fail 'writable lane kernel enforcement'
        return 1
    fi

    # Use the actual host selector, build and mount planner. Expected denial
    # and host preservation are independently asserted by the fixture payload.
    # shellcheck source=tests/lib/core.sh
    source "$JAILBOX_DIR/tests/lib/core.sh" "$JAILBOX_DIR/src"
    local shape parent_policy selected hidden expected actual project_options mount_destinations
    PROJECT_DIR=$project
    REMOTE_PATH=/project
    PROJECT_RESOURCE_PREFIX=$probe_container
    apply_config_defaults
    initialize_dev_image_state
    built_image=$PROJECT_DEV_IMAGE
    mkdir -p "$project/lane/hidden/child" || return 1
    chmod 755 "$project/lane/hidden" "$project/lane/hidden/child" || return 1
    printf secret > "$project/lane/hidden/.secret" || return 1
    printf 'FROM %s\n' "$image" > "$project/lane/Containerfile" || return 1
    cp "$project/lane/Containerfile" "$project/lane/hidden/Containerfile" || return 1
    chmod 644 "$project/lane/Containerfile" "$project/lane/hidden/Containerfile" "$project/lane/hidden/.secret" || return 1
    # shellcheck disable=SC2329 # Called by the shared production validator.
    validation_ssh() { podman exec -i "$probe_container" bash -c "$1"; }
    for shape in exact ancestor; do
        selected=lane/Containerfile; hidden=$selected
        if [[ "$shape" = ancestor ]]; then selected=lane/hidden/Containerfile; hidden=lane/hidden; fi
        rm -f "$project/hardlink" "$project/copy" || return 1
        ln "$project/$selected" "$project/hardlink" || return 1
        cp "$project/$selected" "$project/copy" || return 1
        expected=$(runtime_file_digest "$project/$selected") || return 1
        DEV_CONTAINERFILE=$selected
        build_or_select_dev_image || return 1
        for parent_policy in writable readonly; do
            WRITABLE_PATHS=()
            READONLY_PATHS=(lane/hidden/child)
            if [[ "$parent_policy" = writable ]]; then WRITABLE_PATHS=(lane); else READONLY_PATHS+=(lane); fi
            HIDDEN_PATHS=("$hidden")
            project_options=Z,rprivate
            [[ -z ${WRITABLE_PATHS[*]-} ]] || project_options=Z,ro,rprivate
            build_readonly_mounts || return 1
            podman run -d --name "$probe_container" --network none --read-only \
                --userns="keep-id:uid=$managed_id,gid=$managed_id" --user "$managed_id:$managed_id" \
                --cap-drop=ALL --security-opt=no-new-privileges --entrypoint sleep \
                -v "$project:/project:$project_options" "${WRITABLE_MOUNTS[@]}" "${READONLY_MOUNTS[@]}" \
                "${HIDDEN_MASK_OPTIONS[@]}" "$built_image" 300 >/dev/null || return 1
            # No ordinary mount may expose the masked destination or descendants.
            mount_destinations=$(podman container inspect "$probe_container" --format '{{range .Mounts}}{{println .Destination}}{{end}}') || return 1
            if grep -Eq "^/project/$hidden(/|$)" <<< "$mount_destinations"; then
                fail 'hidden policy emitted a re-exposing overlay'; return 1
            fi
            validate_development_session mounts || return 1
            podman exec -i "$probe_container" bash -s -- "$shape" "$parent_policy" \
                < "$JAILBOX_DIR/tests/lib/sandbox/check-hidden-paths.sh" || { fail "hidden $shape under $parent_policy parent"; return 1; }
            actual=$(runtime_file_digest "$project/$selected") || return 1
            [[ "$actual" = "$expected" ]] || { fail 'mask changed host contents'; return 1; }
            [[ $(cat "$project/lane/hidden/.secret") = secret && -d "$project/lane/hidden/child" ]] || return 1
            cmp "$project/hardlink" "$project/copy" || return 1
            podman rm -f "$probe_container" >/dev/null || return 1
            pass "native $shape mask under $parent_policy parent hides contents and preserves host paths"
        done
    done
)
