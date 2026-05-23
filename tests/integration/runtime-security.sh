#!/bin/bash
# Runtime and security assertions used by integration tests.
#
# This file is sourced by tests/integration/images.sh so these checks run
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
