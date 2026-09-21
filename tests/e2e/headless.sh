#!/bin/bash
# E2E test for jailbox.
#
# For each stage: runs the full jailbox CLI, then while the container is still
# up runs headless SSH assertions covering tools, shell, mounts, and egress.
# All stages run in parallel; output is buffered and printed in defined order.
#
# Prerequisites: run tests/integration/wrapper-images.sh first to build the jailbox-test-* images.
#
# Cleanup: this run records the exact kind and name of every resource it may
# create in a ledger outside its fixture directories (see
# tests/lib/resource-ledger.sh) and removes only those objects, including after
# an interrupted earlier run. Debris from runs that predate the ledger is never
# discovered; remove it by hand, by exact name.
#
# Usage: tests/e2e/headless.sh [stage...]
# Env:   JAILBOX_E2E_REH_RELEASE / JAILBOX_E2E_REH_COMMIT
#                              VSCodium REH build to smoke-test on Alpine
#                              (defaults: CODIUM_VERSION/CODIUM_COMMIT in versions.env)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=tests/lib/logging.sh
source "$JAILBOX_DIR/tests/lib/logging.sh"
test_log_entrypoint "$SCRIPT_DIR/${BASH_SOURCE[0]##*/}" "$@"

# shellcheck source=src/host/core/project-id.sh
source "$JAILBOX_DIR/src/host/core/project-id.sh"
# shellcheck source=versions.env
source "$JAILBOX_DIR/versions.env"
# shellcheck source=tests/lib/run-meta.sh
source "$JAILBOX_DIR/tests/lib/run-meta.sh"
# shellcheck source=tests/lib/resource-ledger.sh
source "$JAILBOX_DIR/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/fixture-ports.sh
source "$JAILBOX_DIR/tests/lib/fixture-ports.sh"

ALL_STAGES=(debian alpine fedora egress)

# VSCodium REH build the Alpine stage probes; shared by the probe and the run
# metadata. Defaults come from versions.env; the canary overrides via env.
REH_RELEASE="${JAILBOX_E2E_REH_RELEASE:-$CODIUM_VERSION}"
REH_COMMIT="${JAILBOX_E2E_REH_COMMIT:-$CODIUM_COMMIT}"

PASSED=0
FAILED=0
stub_dir=""

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

jailbox_container_name() {
    jailbox_resource_prefix_for_path "$1"
}

jailbox_ssh_config() {
    local hash

    hash=$(jailbox_project_hash_for_path "$1")
    printf '%s/jailbox/projects/%s/ssh-generation/ssh_config\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$hash"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

End-to-end jailbox tests. Runs the full CLI pipeline then verifies
tools, shell, mounts, and egress via SSH.

Run tests/integration/wrapper-images.sh first to build the jailbox-test-* images.

Stages: ${ALL_STAGES[*]}

Requires: podman, ssh, ssh-keygen, curl

Environment:
  JAILBOX_E2E_REH_RELEASE
  JAILBOX_E2E_REH_COMMIT  VSCodium REH build to smoke-test on Alpine.
                          Defaults: CODIUM_VERSION/CODIUM_COMMIT in versions.env.
EOF
}

# ── SSH assertion helpers ─────────────────────────────────────────────────────

e2e_ssh() {
    local config="$1" ctr="$2"; shift 2
    ssh -F "$config" -o ConnectTimeout=3 "$ctr" "$@" 2>/dev/null
}

assert_ssh() {
    local config="$1" ctr="$2" desc="$3"; shift 3
    if e2e_ssh "$config" "$ctr" "$@"; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

assert_ssh_fails() {
    local config="$1" ctr="$2" desc="$3"; shift 3
    if e2e_ssh "$config" "$ctr" "$@"; then
        fail "$desc (expected failure, got success)"
    else
        pass "$desc"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

stage_forward_port() {
    case "$1" in
        debian)       echo 24229 ;;
        alpine)       echo 24230 ;;
        fedora)       echo 24231 ;;
        egress)             echo 24234 ;;
        *) die "unknown stage: $1" ;;
    esac
}

stage_reh_probe_port() {
    case "$1" in
        debian)       echo 25229 ;;
        alpine)       echo 25230 ;;
        fedora)       echo 25231 ;;
        egress)             echo 25234 ;;
        *) die "unknown stage: $1" ;;
    esac
}

stage_test_image() {
    case "$1" in
        egress) echo "jailbox-test-debian" ;;
        *)      echo "jailbox-test-$1" ;;
    esac
}

assert_local_forwarding() {
    local config="$1" ctr="$2" port="$3" desc="$4"
    local forward_pid=""

    ssh -F "$config" -N -L "127.0.0.1:${port}:127.0.0.1:2222" "$ctr" >/dev/null 2>&1 &
    forward_pid=$!

    for _ in $(seq 1 20); do
        if timeout 1 bash -c \
            "exec 3<>/dev/tcp/127.0.0.1/$port; IFS= read -r line <&3; [[ \$line == SSH-* ]]" \
            2>/dev/null; then
            kill "$forward_pid" >/dev/null 2>&1 || true
            wait "$forward_pid" 2>/dev/null || true
            pass "$desc"
            return 0
        fi
        sleep 0.1
    done

    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" 2>/dev/null || true
    echo "  Forwarding diagnostic:"
    ssh -vv -F "$config" -o ConnectTimeout=3 -N \
        -L "127.0.0.1:${port}:127.0.0.1:2222" "$ctr" 2>&1 \
        | sed 's/^/    /' &
    forward_pid=$!
    sleep 1
    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" 2>/dev/null || true
    fail "$desc"
}

assert_vscodium_reh_probe() {
    local config="$1" ctr="$2" port="$3" desc="$4"
    local remote_output remote_output_file remote_rc remote_command listening_on tunnel_pid=""

    # Mirrors the current VSCodium/Open Remote SSH server used in editor smoke
    # tests (file-scope REH_RELEASE/REH_COMMIT, from versions.env or env).
    local reh_release="$REH_RELEASE"
    local reh_commit="$REH_COMMIT"

    remote_output_file="$(mktemp)"
    printf -v remote_command 'bash -s -- %q %q' "$reh_release" "$reh_commit"
    ssh -F "$config" -o ConnectTimeout=3 "$ctr" \
        "$remote_command" >"$remote_output_file" 2>&1 < "$JAILBOX_DIR/tests/lib/editor/vscodium-reh-probe.sh"
    remote_rc=$?
    remote_output="$(cat "$remote_output_file")"
    rm -f "$remote_output_file"

    if [[ "$remote_rc" -ne 0 ]]; then
        fail "$desc (server did not start)"
        printf '%s\n' "$remote_output"
        return 0
    fi

    listening_on="$(printf '%s\n' "$remote_output" | sed -n 's/^LISTENING_ON=//p' | tail -1)"
    if [[ -z "$listening_on" ]]; then
        fail "$desc (missing listening port)"
        if [[ -n "$remote_output" ]]; then
            printf '%s\n' "$remote_output"
        else
            echo "  No output captured from remote REH start script"
        fi
        return 0
    fi

    ssh -F "$config" -N -L "127.0.0.1:${port}:127.0.0.1:${listening_on}" "$ctr" >/dev/null 2>&1 &
    tunnel_pid=$!
    sleep 0.5

    if curl -sS --max-time 3 -D - -o /dev/null "http://127.0.0.1:${port}/version" >/dev/null 2>&1; then
        kill "$tunnel_pid" >/dev/null 2>&1 || true
        wait "$tunnel_pid" 2>/dev/null || true
        pass "$desc"
        return 0
    fi

    kill "$tunnel_pid" >/dev/null 2>&1 || true
    wait "$tunnel_pid" 2>/dev/null || true
    fail "$desc (HTTP probe failed for remote port $listening_on)"
}

# ── stub VS Code ──────────────────────────────────────────────────────────────
# Minimal stub: answer extension inventory and validate launch arguments/settings.
# The real SSH assertions run after jailbox exits, while the container is up.

setup_stub_editor() {
    cp "$JAILBOX_DIR/tests/fixtures/headless-editor.sh" "$stub_dir/code"
    chmod +x "$stub_dir/code"
    ln -sf "$stub_dir/code" "$stub_dir/codium"
}

# ── run_e2e_case ──────────────────────────────────────────────────────────────
# Designed to run inside a subshell. PASSED/FAILED are subshell-local.

headless_fixture() {
    local stage="$1" candidate offset port attempt
    for ((attempt=1; attempt<=100; attempt++)); do
        candidate=$(mktemp -d "/tmp/jailbox-e2e-${stage}.XXXXXX") || return 1
        offset=$(jailbox_project_hash_port_offset "$(jailbox_project_hash_for_path "$candidate")") || {
            rm -rf "$candidate"; return 1;
        }
        port=$((49152 + offset))
        # Claims live until the entire run ends: later stop/relaunch assertions
        # must not let another stage borrow this port while it is unbound.
        if test_fixture_port_available "$port" && mkdir "$stub_dir/ports/$port" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
        rm -rf "$candidate"
    done
    die "could not allocate a free SSH port outside the ephemeral range for $stage"
}

cleanup_e2e_stage() {
    echo "$PASSED $FAILED" > "$stage_counts_file"
    if [[ -n "$project_dir" ]]; then
        (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --clean 2>/dev/null || true)
        rm -rf "$project_dir"
    fi
}

run_e2e_case_logged() {
    ( run_e2e_case "$@" ) 2>&1 | test_timestamp_stream
}

run_e2e_case() {
    local stage="$1"
    local log_dir="$2"
    local status_artifact_dir="$log_dir/$stage.status" status_observation=0
    mkdir -p "$status_artifact_dir" || { fail 'could not create status artifact directory'; return 1; }

    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope.
    project_dir=""

    stage_counts_file="$log_dir/$stage.counts"
    trap cleanup_e2e_stage EXIT

    echo ""
    echo "── e2e: $stage (user: jailbox) ─────────────────────────────────────"

    project_dir=$(headless_fixture "$stage") || return 1
    # Before anything can create them, and outside the fixture directory.
    ledger_record_project_resources "$project_dir" || return 1
    git -C "$project_dir" init -q
    printf 'initial\n' > "$project_dir/README.txt"
    git -C "$project_dir" add README.txt
    git -C "$project_dir" \
        -c user.name=jailbox-e2e \
        -c user.email=jailbox-e2e@example.invalid \
        commit -q -m "initial"

    local dev_image
    dev_image=$(stage_test_image "$stage")
    if [[ "$stage" = debian ]]; then
        assert_isolated_status_inventory "$project_dir" "$dev_image" || {
            fail 'isolated status inventory fixtures failed'; return 1;
        }
    fi

    mkdir -p "$project_dir/config"
    cat > "$project_dir/config/runtime.conf" << EOF
DEV_IMAGE=${dev_image}
EOF
    if [[ "$stage" = debian ]]; then
        # Reuse the existing stop/relaunch cycle to test changed build inputs.
        printf 'FROM %s\nCOPY rebuild-payload /rebuild-payload\n' "$dev_image" > "$project_dir/Containerfile"
        printf 'initial\n' > "$project_dir/rebuild-payload"
        printf 'DEV_CONTAINERFILE=Containerfile\n' > "$project_dir/config/runtime.conf"
    fi
    if [[ "$stage" == "egress" ]]; then
        printf 'EGRESS_ALLOW=api.ipify.org\n' >> "$project_dir/config/runtime.conf"
    fi
    # Explicit anchors let machine attachments reproduce this file-driven
    # fixture's complete mount inventory with identical environment policy.
    printf 'READONLY_PATHS=jailbox.conf,config/runtime.conf\n' >> "$project_dir/config/runtime.conf"

    # Launch requires the default policy anchor even when it selects another
    # config. Create it with the real command so this gate covers the
    # init -> launch flow rather than a hand-written fixture file.
    if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" init) >/dev/null; then
        pass "init creates the default policy anchor"
    else
        fail "init could not create the default policy anchor"
        return 1
    fi

    export JAILBOX_E2E_PROJECT="$project_dir"

    # ── Phase 1: full jailbox pipeline ────────────────────────────────────────
    if (
        cd "$project_dir"
        JAILBOX_E2E_REJECT_EDITOR=1 PATH="$stub_dir:$PATH" \
            "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor
    ) 2>&1; then
        pass "up pipeline (build → start → SSH wait → validation)"
    else
        fail "pipeline failed"
        return 1
    fi

    # ── Phase 2: headless assertions (container still running) ────────────────
    local ssh_cfg
    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    local ctr
    ctr=$(jailbox_container_name "$project_dir")
    assert_status "$project_dir" running
    local forward_port reh_probe_port
    forward_port=$(stage_forward_port "$stage")
    reh_probe_port=$(stage_reh_probe_port "$stage")

    # Shell and tools
    assert_ssh "$ssh_cfg" "$ctr" "login shell is executable" \
        "shell=\$(grep -m1 '^jailbox:' /etc/passwd | cut -d: -f7); test -x \"\$shell\""
    assert_ssh "$ssh_cfg" "$ctr" "bash available" "command -v bash >/dev/null"
    assert_ssh "$ssh_cfg" "$ctr" "git available"  "git --version >/dev/null"
    if (
        export JAILBOX_CONFIG_DEV_IMAGE="$dev_image"
        export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
        export JAILBOX_CONFIG_READONLY_PATHS_1=config/runtime.conf
        if [[ "$stage" = debian ]]; then
            unset JAILBOX_CONFIG_DEV_IMAGE
            export JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile
        elif [[ "$stage" = egress ]]; then
            export JAILBOX_CONFIG_EGRESS_ALLOW_0=api.ipify.org
        fi
        bash "$JAILBOX_DIR/tests/lib/shell-runtime.sh" "$JAILBOX_DIR" "$project_dir" "$ctr" "$log_dir/$stage.shell"
    ); then
        pass 'public shell terminal and login behavior'
    else
        fail 'public shell terminal and login behavior'
    fi
    assert_local_forwarding "$ssh_cfg" "$ctr" "$forward_port" "SSH local forwarding works"
    if [[ "$stage" == "alpine" ]]; then
        assert_vscodium_reh_probe "$ssh_cfg" "$ctr" "$reh_probe_port" "VSCodium REH reachable through OpenSSH tunnel"
    fi

    # Mounts
    assert_ssh "$ssh_cfg" "$ctr" "home writable" "test -w \"\$HOME\""
    assert_ssh "$ssh_cfg" "$ctr" "project mount writable" \
        "touch /home/jailbox/project/.e2e-test && rm /home/jailbox/project/.e2e-test"
    assert_ssh "$ssh_cfg" "$ctr" "editor-style project write works with managed UID" \
        "printf '%s\n' edited > /home/jailbox/project/editor-write.txt"
    assert_ssh "$ssh_cfg" "$ctr" "git index write works with managed UID" \
        "git -C /home/jailbox/project add editor-write.txt"
    assert_ssh "$ssh_cfg" "$ctr" "selected in-project config is immutable" \
        "! printf 'DEV_IMAGE=attacker\\n' >> /home/jailbox/project/config/runtime.conf 2>/dev/null && ! rm /home/jailbox/project/config/runtime.conf 2>/dev/null"
    # The anchor is not the selected config for this run; it must still be
    # read-only so the sandbox cannot author policy for a later bare launch.
    assert_ssh "$ssh_cfg" "$ctr" "default config anchor is immutable under external selection" \
        "! printf 'READONLY_PATHS=attacker\\n' >> /home/jailbox/project/jailbox.conf 2>/dev/null && ! rm /home/jailbox/project/jailbox.conf 2>/dev/null"
    if [[ "$stage" != "egress" ]]; then
        assert_ssh "$ssh_cfg" "$ctr" "no stale managed downloader proxy blocks" \
            'bash -s -- absent' < "$JAILBOX_DIR/tests/lib/sandbox/check-managed-proxy.sh"
    fi

    # Command mode must not create host-side editor settings.
    local settings_hash settings_path
    settings_hash=$(jailbox_project_hash_for_path "$project_dir")
    settings_path="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/editor-profiles/$settings_hash/User/settings.json"
    if [[ ! -e "$settings_path" ]]; then
        pass "up creates no editor settings"
    else
        fail "up creates no editor settings"
    fi

    # Egress policy (only run for the egress stage)
    if [[ "$stage" == "egress" ]]; then
        local proxy_ctr="${ctr}-proxy" proxy_url state_hash filter_path

        proxy_url=$(grep -Eo 'HTTPS_PROXY=[^ ]+' "$ssh_cfg" | head -1 | cut -d= -f2-)
        state_hash=$(jailbox_project_hash_for_path "$project_dir")
        filter_path="${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/projects/$state_hash/tinyproxy-filter"

        assert_ssh "$ssh_cfg" "$ctr" "HTTPS_PROXY is set in SSH session" \
            "[ -n \"\$HTTPS_PROXY\" ]"
        assert_ssh "$ssh_cfg" "$ctr" "curl downloader proxy block is managed" \
            "bash -s -- curl $(printf '%q' "$proxy_url")" < "$JAILBOX_DIR/tests/lib/sandbox/check-managed-proxy.sh"
        assert_ssh "$ssh_cfg" "$ctr" "wget downloader proxy block is managed" \
            "bash -s -- wget $(printf '%q' "$proxy_url")" < "$JAILBOX_DIR/tests/lib/sandbox/check-managed-proxy.sh"
        if [[ "$proxy_url" =~ ^http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8888$ ]] &&
            grep -Fq "HTTPS_PROXY=$proxy_url" "$ssh_cfg"; then
            pass "generated SSH config carries proxy environment"
        else
            fail "generated SSH config carries proxy environment"
        fi
        assert_ssh_fails "$ssh_cfg" "$ctr" "DNS resolution is disabled on egress network when getent is available" \
            "command -v getent >/dev/null 2>&1 && getent hosts api.ipify.org"
        if [[ -f "$filter_path" ]] &&
            grep -Fxq '^api\.ipify\.org$' "$filter_path" &&
            ! grep -Fxq '^github\.com$' "$filter_path" &&
            ! grep -Fxq '^githubusercontent\.com$' "$filter_path"; then
            pass "up filter contains configured hosts without editor bootstrap hosts"
        else
            fail "up filter contains configured hosts without editor bootstrap hosts"
        fi
        assert_ssh_fails "$ssh_cfg" "$ctr" "direct HTTP(S) bypassing proxy is blocked" \
            "curl --noproxy '*' --connect-timeout 5 --max-time 5 -fs https://example.com"
        assert_ssh_fails "$ssh_cfg" "$ctr" "raw TCP to external IP is blocked" \
            "timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/443' 2>/dev/null"
        assert_ssh "$ssh_cfg" "$ctr" "curl via proxy to allowed host (api.ipify.org) succeeds" \
            "curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org >/dev/null"
        assert_ssh "$ssh_cfg" "$ctr" "wget via managed proxy config to allowed host succeeds when available" \
            "if command -v wget >/dev/null 2>&1; then wget -qO- --timeout=10 https://api.ipify.org >/dev/null; fi"
        assert_ssh_fails "$ssh_cfg" "$ctr" "curl via proxy to disallowed host fails" \
            "curl --connect-timeout 10 --max-time 10 -fs http://not-in-allowlist.example.org"
        assert_ssh_fails "$ssh_cfg" "$ctr" "proxy rejects CONNECT to non-443 port" \
            "curl --connect-timeout 5 --max-time 5 -fs https://api.ipify.org:8080/"

        # ── Proxy network diagnostics ─────────────────────────────────────────
        echo "  [diag] proxy env vars in SSH session:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "env | grep -i proxy || echo '(none)'" 2>/dev/null || true
        echo "  [diag] SetEnv lines in generated SSH config:"
        grep -i setenv "$ssh_cfg" 2>/dev/null || echo "(none)"
        echo "  [diag] managed downloader proxy blocks:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            'bash -s -- proxy' < "$JAILBOX_DIR/tests/lib/editor/remote-diagnostics.sh" \
            2>/dev/null || true
        echo "  [diag] tinyproxy filter:"
        sed 's/^/    /' "$filter_path" 2>/dev/null || echo "    (missing)"
        echo "  [diag] proxy direct reach (wget api.ipify.org, bypassing tinyproxy):"
        podman exec "$proxy_ctr" wget -qO- --timeout=5 http://api.ipify.org 2>&1 || echo "(wget failed)"
        echo "  [diag] curl verbose via proxy (inside jailbox):"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "curl -v --connect-timeout 5 --max-time 10 https://api.ipify.org" 2>&1 || true
        echo "  [diag] tinyproxy logs:"
        podman logs "$proxy_ctr" 2>&1 || true
    fi

    # ── Phase 3: convergence and explicit stop boundary ────────────────────
    local relaunch_output volume_name generation_dir container_id generation_before
    volume_name="${ctr}-home"
    generation_dir=$(dirname "$ssh_cfg")
    container_id=$(podman container inspect "$ctr" --format "{{.Id}}")
    generation_before=$(find "$generation_dir" -type f -exec cksum {} + | sort)
    # shellcheck disable=SC2016
    assert_ssh "$ssh_cfg" "$ctr" "write home content before reuse" 'printf retained > "$HOME/retention-marker"'
    if [[ "$stage" = debian ]]; then
        printf 'ENV REBUILD_TEST=changed\n' >> "$project_dir/Containerfile"
        printf 'changed\n' > "$project_dir/rebuild-payload"
    fi
    if relaunch_output=$( (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor) 2>&1); then
        pass "running up reuses the sandbox"
    else
        fail "running up failed: $relaunch_output"
    fi
    assert_eq "reuse preserves container identity" "$container_id" "$(podman container inspect "$ctr" --format "{{.Id}}")"
    assert_eq "reuse preserves SSH generation" "$generation_before" "$(find "$generation_dir" -type f -exec cksum {} + | sort)"
    if [[ "$stage" = debian ]]; then
        # shellcheck disable=SC2016  # Expanded by the remote shell.
        assert_ssh "$ssh_cfg" "$ctr" 'changed build inputs do not rebuild on reuse' 'test "$(cat /rebuild-payload)" = initial'
    fi
    podman stop "$ctr" >/dev/null
    assert_status "$project_dir" stopped
    if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor); then
        pass "up resumes the stopped generation"
    else
        fail "up could not resume the stopped generation"
    fi
    assert_eq "resume preserves container identity" "$container_id" "$(podman container inspect "$ctr" --format "{{.Id}}")"
    assert_eq "resume preserves SSH generation" "$generation_before" "$(find "$generation_dir" -type f -exec cksum {} + | sort)"
    # shellcheck disable=SC2016
    assert_ssh "$ssh_cfg" "$ctr" "reuse and resume preserve home content" 'test "$(cat "$HOME/retention-marker")" = retained'
    if [[ "$stage" == egress ]]; then
        podman stop "${ctr}-proxy" >/dev/null
        if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor); then
            pass "up starts a stopped proxy beneath a running development container"
        else
            fail "mixed-state proxy resume failed"
            report_proxy_connectivity "$ssh_cfg" "$ctr"
        fi
        podman rm -f "${ctr}-proxy" >/dev/null
        if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor); then
            pass "up creates a missing proxy on surviving networks"
        else
            fail "partial proxy convergence failed"
            report_proxy_connectivity "$ssh_cfg" "$ctr"
        fi
        assert_eq "partial convergence preserves development identity" "$container_id" "$(podman container inspect "$ctr" --format "{{.Id}}")"
        local digest malformed
        digest=$(podman container inspect "$ctr" --format '{{index .Config.Labels "jailbox.config-digest"}}')
        for malformed in '' invalid "$digest"$'\n'; do
            podman network create --label "jailbox.config-digest=$malformed" "${ctr}-net" >/dev/null
            if relaunch_output=$(cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf --no-editor 2>&1); then
                fail 'malformed digest on an out-of-mode network must refuse'
            elif [[ "$relaunch_output" == *'configuration digest'* || "$relaunch_output" == *'digest label'* ]]; then
                pass 'complete-inventory digest gate rejects malformed metadata'
            else
                fail "unexpected digest refusal: $relaunch_output"
            fi
            assert_eq 'digest refusal preserves development identity' "$container_id" "$(podman container inspect "$ctr" --format '{{.Id}}')"
            podman network rm "${ctr}-net" >/dev/null
        done
    fi

    if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" stop) >/dev/null 2>&1; then
        pass "stop removes the running sandbox"
    else
        fail "stop removes the running sandbox"
    fi
    if ! podman container exists "$ctr" 2>/dev/null && \
        ! podman container exists "${ctr}-proxy" 2>/dev/null; then
        pass "stop leaves no development or proxy container"
    else
        fail "stop leaves no development or proxy container"
    fi
    if podman volume exists "$volume_name" 2>/dev/null; then
        pass "stop preserves the home volume"
    else
        fail "stop preserves the home volume"
    fi
    # Stop ends the generation with its container; unrelated project runtime
    # state, such as the generated gitconfig, stays in the state directory.
    generation_dir=$(dirname "$ssh_cfg")
    if [[ ! -e "$generation_dir" ]] && [[ -d "$(dirname "$generation_dir")" ]]; then
        pass "stop removes the SSH generation and preserves the project state directory"
    else
        fail "stop removes the SSH generation and preserves the project state directory"
    fi
    if [[ "$stage" == "egress" ]]; then
        if ! podman network exists "${ctr}-net-internal" 2>/dev/null && \
            ! podman network exists "${ctr}-net-external" 2>/dev/null; then
            pass "stop removes the egress networks"
        else
            fail "stop removes the egress networks"
        fi
    elif ! podman network exists "${ctr}-net" 2>/dev/null; then
        pass "stop removes the project network"
    else
        fail "stop removes the project network"
    fi
    if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" stop) >/dev/null 2>&1; then
        pass "repeated stop succeeds"
    else
        fail "repeated stop succeeds"
    fi

    if [[ "$stage" == egress ]]; then
        printf 'DEV_IMAGE=%s\nEDITOR=codium\nEGRESS_ALLOW=example.com\nREADONLY_PATHS=jailbox.conf,config/runtime.conf\n' "$dev_image" > "$project_dir/config/runtime.conf"
    fi
    # A bare launch after the explicit stop restores the positive editor-stub
    # coverage and proves that editor discovery changes only filtered policy.
    if (
        cd "$project_dir"
        PATH="$stub_dir:$PATH" "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf
    ) 2>&1; then
        pass "bare launch completes through the editor stub"
    else
        fail "bare launch through the editor stub failed"
        return 1
    fi
    # shellcheck disable=SC2016  # Expanded by the remote shell.
    assert_ssh "$ssh_cfg" "$ctr" "home content survives stop and relaunch" 'test "$(cat "$HOME/retention-marker")" = retained'
    if [[ "$stage" = debian ]]; then
        # shellcheck disable=SC2016  # Expanded by the remote shell.
        assert_ssh "$ssh_cfg" "$ctr" 'stop then launch incorporates copied build input' 'test "$(cat /rebuild-payload)" = changed'
        assert_eq 'stop then launch incorporates Containerfile changes' changed "$(podman exec "$ctr" printenv REBUILD_TEST)"
    fi
    if [[ -f "$settings_path" ]] && grep -Fq '"remote.SSH.configFile"' "$settings_path"; then
        pass "bare launch writes editor SSH settings"
    else
        fail "bare launch writes editor SSH settings"
    fi
    if [[ "$stage" == "egress" ]]; then
        if grep -Fxq '^example\.com$' "$filter_path" &&
            grep -Fxq '^github\.com$' "$filter_path" &&
            grep -Fxq '^githubusercontent\.com$' "$filter_path"; then
            pass "bare VSCodium launch adds editor bootstrap hosts"
        else
            fail "bare VSCodium launch adds editor bootstrap hosts"
        fi
        if bash "$JAILBOX_DIR/tests/lib/frontend-attachment.sh" "$JAILBOX_DIR" "$project_dir" "$ctr" "$log_dir/$stage.frontend"; then
            pass 'filtered editor launch supports public exec and shell'
        else
            fail 'filtered editor launch supports public exec and shell'
        fi
    fi

    container_id=$(podman container inspect "$ctr" --format '{{.Id}}')
    if (cd "$project_dir" && PATH="$stub_dir:$PATH" "$JAILBOX_DIR/src/jailbox" --config config/runtime.conf); then
        pass 'bare running reuse opens the editor after convergence'
    else
        fail 'bare running reuse failed'
    fi
    assert_eq 'bare reuse preserves container identity' "$container_id" "$(podman container inspect "$ctr" --format '{{.Id}}')"

    if (cd "$project_dir" && "$JAILBOX_DIR/src/jailbox" stop) >/dev/null 2>&1; then
        pass "stop removes the bare-launch sandbox"
    else
        fail "stop removes the bare-launch sandbox"
    fi
    assert_home_lifecycle "$project_dir" "$ctr" "$dev_image"
}

report_proxy_connectivity() {
    local config="$1" container="$2" name
    for name in "$container" "${container}-proxy"; do
        printf '  [diag] %s network attachments:\n' "$name"
        podman container inspect "$name" --format '{{json .NetworkSettings.Networks}}' || true
        printf '  [diag] %s routes and ARP cache:\n' "$name"
        podman exec "$name" sh -c 'cat /proc/net/route /proc/net/arp' || true
    done
    echo '  [diag] development-to-proxy request after readiness failure:'
    ssh -F "$config" -o ConnectTimeout=3 "$container" \
        'curl -q --noproxy "" --proxy "$HTTP_PROXY" -v --connect-timeout 3 --max-time 5 http://jailbox-egress-diagnostic.invalid/' || true
}

# Exercise ephemeral generations and image cleanup across wrapper distributions.
# All names are the stage's already-ledgered exact project names.
assert_home_lifecycle() {
    local project="$1" prefix="$2" dev_image="$3" home
    home="$prefix-home"

    # Constructed home metadata and recovery now run in the shared lifecycle
    # matrix. Keep generation resume coverage across wrapper distributions.
    (cd "$project" && "$JAILBOX_DIR/src/jailbox" --clean) >/dev/null 2>&1 || {
        fail "clean before ephemeral launch"; return 1;
    }
    assert_status "$project" absent

    # Build a derived dev image so clean must remove its wrapper child first.
    # A derived tag suffices to exercise cleanup ordering; avoid a filesystem
    # change that would force another full wrapper package installation.
    printf 'FROM %s\n' "$dev_image" > "$project/Containerfile.home"
    if (cd "$project" && JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile.home \
        JAILBOX_CONFIG_EPHEMERAL_HOME=true "$JAILBOX_DIR/src/jailbox" up); then
        if [ "$(podman volume inspect "$home" --format '{{index .Labels "jailbox.ephemeral-home"}}')" = true ]; then
            pass "launch records effective ephemeral retention"
        else
            fail "launch records effective ephemeral retention"
        fi
        local ssh_config generation_before
        ssh_config=$(jailbox_ssh_config "$project")
        generation_before=$(find "$(dirname "$ssh_config")" -type f -exec cksum {} + | sort)
        # shellcheck disable=SC2016
        ssh -F "$ssh_config" "$prefix" 'printf retained > "$HOME/ephemeral-marker"'
        podman stop "$prefix" >/dev/null
        if (cd "$project" && JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile.home \
            JAILBOX_CONFIG_EPHEMERAL_HOME=true "$JAILBOX_DIR/src/jailbox" up); then
            pass 'up resumes an ephemeral generation'
        else
            fail 'ephemeral resume failed'
        fi
        assert_eq 'ephemeral resume preserves SSH identity' "$generation_before" \
            "$(find "$(dirname "$ssh_config")" -type f -exec cksum {} + | sort)"
        # shellcheck disable=SC2016
        assert_ssh "$ssh_config" "$prefix" 'ephemeral home survives resume' 'test "$(cat "$HOME/ephemeral-marker")" = retained'
        (cd "$project" && "$JAILBOX_DIR/src/jailbox" stop) >/dev/null 2>&1 || {
            fail "stop ephemeral generation"; return 1;
        }
        if ! podman volume exists "$home"; then
            pass "stop deletes the ephemeral generation's home"
        else
            fail "stop deletes the ephemeral generation's home"
        fi
        assert_status "$project" absent
    else
        fail "ephemeral generation launch"
    fi
    (cd "$project" && "$JAILBOX_DIR/src/jailbox" --clean) >/dev/null 2>&1 || {
        fail "clean derived dev image and wrapper"; return 1;
    }
    assert_status "$project" absent
    for home in "$prefix-dev" "$prefix-image" "$prefix-proxy"; do
        if podman image exists "$home"; then
            fail "clean removes derived image $home"
        else
            pass "clean removes derived image $home"
        fi
    done
    if podman image exists "$dev_image"; then
        pass "clean preserves external dev image"
    else
        fail "clean preserves external dev image"
    fi
}

# Keep isolated inventory resources in the runtime gate; adversarial lifecycle
# combinations and home-label retention expectations belong to the shared matrix.
assert_status() {
    local project="$1" expected="$2" output
    status_observation=$((status_observation + 1))
    output="$status_artifact_dir/$status_observation-$expected"
    printf '%s\n' "$expected" > "$output.expected" || return 1
    if (cd "$project" && "$JAILBOX_DIR/src/jailbox" status) > "$output.stdout" 2> "$output.stderr" &&
        cmp -s "$output.expected" "$output.stdout"; then
        pass "status reports $expected with exact framing"
    else
        fail "status did not report $expected with exact framing"
        return 1
    fi
}

assert_isolated_status_inventory() {
    local project="$1" image="$2" prefix kind name
    prefix=$(jailbox_container_name "$project") || return 1
    assert_status "$project" absent || return 1
    for kind in container network volume; do
        local -a names=()
        case "$kind" in
            container) names=("$prefix" "$prefix-proxy") ;;
            network) names=("$prefix-net" "$prefix-net-internal" "$prefix-net-external") ;;
            volume) names=("$prefix-home") ;;
        esac
        for name in "${names[@]}"; do
            case "$kind" in
                container) podman create --name "$name" --network none "$image" true >/dev/null || return 1 ;;
                network) podman network create --internal "$name" >/dev/null || return 1 ;;
                volume) podman volume create "$name" >/dev/null || return 1 ;;
            esac
            assert_status "$project" stopped || return 1
            podman "$kind" exists "$name" || { fail 'status removed inventory resource'; return 1; }
            case "$kind" in
                container) podman rm "$name" >/dev/null || return 1 ;;
                *) podman "$kind" rm "$name" >/dev/null || return 1 ;;
            esac
            assert_status "$project" absent || return 1
        done
    done
    podman tag "$image" "$prefix-image" || return 1
    assert_status "$project" absent || return 1
    podman image exists "$prefix-image" || { fail 'status removed image'; return 1; }
    podman image rm "$prefix-image" >/dev/null || return 1
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage; exit 0
    fi

    command -v podman     >/dev/null 2>&1 || die "podman is required"
    command -v ssh        >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
    command -v curl       >/dev/null 2>&1 || die "curl is required"
    command -v python3    >/dev/null 2>&1 || die "python3 is required"
    command -v git        >/dev/null 2>&1 || die "git is required"

    local stages=("$@")
    [ ${#stages[@]} -eq 0 ] && stages=("${ALL_STAGES[@]}")

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do [ "$s" = "$a" ] && valid=1 && break; done
        [ $valid -eq 1 ] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
    done

    local required_image
    for stage in "${stages[@]}"; do
        required_image=$(stage_test_image "$stage")
        podman image exists "$required_image" 2>/dev/null || \
            die "$required_image not found - run tests/integration/wrapper-images.sh first"
    done

    ledger_begin_run e2e || die "could not initialize the test resource ledger"
    ledger_prune_stale_runs

    local log_dir rel_log_dir
    log_dir="$JAILBOX_DIR/testlog/e2e-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$log_dir"
    write_run_meta "$log_dir"
    run_meta_reh "$log_dir" "$REH_RELEASE" "$REH_COMMIT"
    stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' EXIT
    mkdir "$stub_dir/ports"

    setup_stub_editor

    echo "jailbox e2e tests (parallel)"
    echo "Stages : ${stages[*]}"
    echo ""

    local -A stage_pids=()
    for stage in "${stages[@]}"; do
        printf "  ⏳ %s\n" "$stage"
        # The redirect belongs to the worker's own output. A registration
        # failure lands in that log too, so report it on the terminal rather
        # than aborting the run with nothing visible.
        if ! ledger_start_worker run_e2e_case_logged "$stage" "$log_dir" \
            > "$log_dir/${stage}.log" 2>&1; then
            die "could not register the $stage stage with the resource ledger (see $log_dir/${stage}.log)"
        fi
        stage_pids[$stage]=$LEDGER_WORKER_PID
    done
    echo ""

    local -A reported=()
    local last_progress
    last_progress=$SECONDS
    while [[ ${#reported[@]} -lt ${#stages[@]} ]]; do
        for stage in "${stages[@]}"; do
            [[ "${reported[$stage]+_}" ]] && continue
            local p=0 f=0
            if [[ -f "$log_dir/${stage}.counts" ]]; then
                read -r p f < "$log_dir/${stage}.counts" || true
                if [[ "$f" -eq 0 ]]; then
                    printf "  ✅ %-16s (%d passed)\n" "$stage" "$p"
                else
                    printf "  ❌ %-16s (%d passed, %d failed)\n" "$stage" "$p" "$f"
                    sed 's/^/      /' "$log_dir/${stage}.log" 2>/dev/null || true
                fi
                reported[$stage]=1
            elif ! kill -0 "${stage_pids[$stage]}" 2>/dev/null; then
                printf "  ❌ %-16s (crashed)\n" "$stage"
                sed 's/^/      /' "$log_dir/${stage}.log" 2>/dev/null || true
                reported[$stage]=1
            fi
        done
        if [[ ${#reported[@]} -lt ${#stages[@]} && $((SECONDS - last_progress)) -ge 30 ]]; then
            printf "  … still running:"
            for stage in "${stages[@]}"; do
                [[ "${reported[$stage]+_}" ]] || printf " %s" "$stage"
            done
            printf "\n"
            last_progress=$SECONDS
        fi
        [[ ${#reported[@]} -lt ${#stages[@]} ]] && sleep 0.3
    done
    echo ""

    for pid in "${stage_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Every stage has finished, so anything still standing under a recorded
    # name is this run's leftover. Whatever survives stays in the ledger for
    # the next run.
    ledger_sweep_own_run

    local total_passed=0 total_failed=0 p f
    for stage in "${stages[@]}"; do
        if [[ -f "$log_dir/${stage}.counts" ]]; then
            read -r p f < "$log_dir/${stage}.counts"
            total_passed=$((total_passed + p))
            total_failed=$((total_failed + f))
        else
            total_failed=$((total_failed + 1))
        fi
    done

    echo ""
    echo "──────────────────────────────────────────────────────────────────────"
    echo "Results: $total_passed passed, $total_failed failed"
    rel_log_dir=$(run_log_path "$log_dir")
    echo "Full logs: $rel_log_dir"
    if [[ "$total_failed" -gt 0 ]]; then
        echo "Failed stage logs:"
        for stage in "${stages[@]}"; do
            if [[ ! -f "$log_dir/${stage}.counts" ]]; then
                echo "  $rel_log_dir/${stage}.log"
                continue
            fi
            read -r p f < "$log_dir/${stage}.counts"
            [[ "$f" -gt 0 ]] && echo "  $rel_log_dir/${stage}.log"
        done
    fi
    [ $total_failed -eq 0 ] || exit 1
}

main "$@"
