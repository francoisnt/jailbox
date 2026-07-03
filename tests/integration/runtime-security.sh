#!/bin/bash
# Runtime and security assertions used by integration tests.
#
# This file is sourced by tests/integration/wrapper-images.sh so these checks run
# during the existing integration container launch instead of starting another
# Podman-heavy suite.

assert_runtime_dir_valid() {
    local config="$1" desc="$2"

    # shellcheck disable=SC2016  # remote script expands inside the container
    if ssh_run "$config" '
        set -e

        test -d /run/jailbox-sshd
        test -w /run/jailbox-sshd

        runtime_uid=$(
            stat -c "%u" /run/jailbox-sshd 2>/dev/null ||
            stat -f "%u" /run/jailbox-sshd
        )
        test "$runtime_uid" = "$(id -u)"

        runtime_mode=$(
            stat -c "%a" /run/jailbox-sshd 2>/dev/null ||
            stat -f "%Lp" /run/jailbox-sshd
        )
        case "$runtime_mode" in
            700|1700) ;;
            *) exit 1 ;;
        esac
    ' 2>/dev/null; then
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
    logs=""
    rc=0

    podman rm -f "$bad_ctr" >/dev/null 2>&1 || true

    if podman run -d \
        --name "$bad_ctr" \
        --replace \
        --userns=keep-id \
        --user "${bad_uid}:${bad_uid}" \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --tmpfs /run:rw,size=64m \
        -v "${bad_home}:/home/jailbox:Z" \
        -v "${bad_runtime}:/run/jailbox-sshd:Z" \
        -v "${ssh_dir}/key.pub:/etc/ssh/jailbox_authorized_keys.source:ro,Z" \
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

# host/dev-image.sh validation probes execute the dev image (including its
# entrypoint) before any jailbox runtime hardening applies, so podman_probe
# must supply its own constraints: no network and no capabilities.
# Sourcing happens inside the command substitutions because dev-image.sh
# defines jailbox_install_cache_bust, which would otherwise shadow this
# harness's version of that helper.
assert_probe_hardening() {
    local image="$1"
    local interfaces capabilities

    interfaces=$(
        # shellcheck source=host/dev-image.sh
        source "$JAILBOX_DIR/host/dev-image.sh"
        podman_probe "$image" /bin/sh -c 'ls /sys/class/net' 2>/dev/null || true
    )
    if [ "$interfaces" = "lo" ]; then
        pass "dev-image probe has no network interfaces"
    else
        fail "dev-image probe has no network interfaces (got: ${interfaces:-none})"
    fi

    capabilities=$(
        # shellcheck source=host/dev-image.sh
        source "$JAILBOX_DIR/host/dev-image.sh"
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
    local output

    # shellcheck source=host/validation.sh
    source "$JAILBOX_DIR/host/validation.sh"

    # Globals consumed by check_readonly_mounts. CONTAINER_NAME doubles as
    # the ssh host alias, which this harness names jailbox-test.
    SSH_CONFIG="$config"
    CONTAINER_NAME="jailbox-test"
    PROJECT_DIR="$project_dir"
    REMOTE_PATH="/home/jailbox/project"
    WARNINGS=0

    READONLY_PATHS=("Containerfile" ".git/hooks")
    output=$(check_readonly_mounts)
    if printf '%s\n' "$output" | grep -q "Read-only mounts validated (2 entries checked)"; then
        pass "read-only validation passes for correctly mounted paths"
    else
        fail "read-only validation passes for correctly mounted paths"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi

    READONLY_PATHS=("Containerfile" ".git/hooks" "Dockerfile" ".github/workflows")
    output=$(check_readonly_mounts)

    if printf '%s\n' "$output" | grep -q "appears writable: Dockerfile"; then
        pass "read-only validation flags writable file"
    else
        fail "read-only validation flags writable file"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi

    if printf '%s\n' "$output" | grep -q "appears writable: .github/workflows"; then
        pass "read-only validation flags writable directory"
    else
        fail "read-only validation flags writable directory"
        printf '%s\n' "$output" | sed 's/^/    /'
    fi

    if printf '%s\n' "$output" | grep -Eq "appears writable: (Containerfile|\.git/hooks)"; then
        fail "read-only validation stays quiet for read-only paths"
        printf '%s\n' "$output" | sed 's/^/    /'
    else
        pass "read-only validation stays quiet for read-only paths"
    fi
}
