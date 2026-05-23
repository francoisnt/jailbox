#!/bin/bash
# E2E test for jailbox.
#
# For each stage: runs the full jailbox CLI, then while the container is still
# up runs headless SSH assertions covering security, tools, shell, and mounts.
# All stages run in parallel; output is buffered and printed in defined order.
#
# Prerequisites: run tests/integration-images.sh first to build the jailbox-test-* images.
#
# Usage: tests/e2e-headless.sh [stage...]
# Env:   JAILBOX_E2E_REH_RELEASE / JAILBOX_E2E_REH_COMMIT
#                              VSCodium REH build to smoke-test on Alpine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(dirname "$SCRIPT_DIR")"

ALL_STAGES=(debian alpine fedora custom-user uid-mismatch egress)

PASSED=0
FAILED=0
stub_dir=""

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

jailbox_container_name() {
    printf 'jailbox-%s\n' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}

jailbox_ssh_config() {
    printf '%s/.jailbox/ssh_config\n' "$1"
}

write_jailbox_workspace_config() {
    local project_dir="$1"
    local ctr="$2"
    local remote_path="$3"

    mkdir -p "$project_dir/.jailbox"
    chmod 700 "$project_dir/.jailbox"
    printf '.jailbox/\n' > "$project_dir/.gitignore"
    cat > "$project_dir/.jailbox/jailbox.code-workspace" << EOF
{
  "folders": [
    {
      "uri": "vscode-remote://ssh-remote+${ctr}${remote_path}"
    }
  ],
  "settings": {
    "remote.SSH.configFile": "${project_dir}/.jailbox/ssh_config"
  }
}
EOF
    chmod 600 "$project_dir/.jailbox/jailbox.code-workspace"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

End-to-end jailbox tests. Runs the full CLI pipeline then verifies
security, tools, shell, and mounts via SSH.

Run tests/integration-images.sh first to build the jailbox-test-* images.

Stages: ${ALL_STAGES[*]}

Requires: podman, ssh, ssh-keygen, curl

Environment:
  JAILBOX_E2E_REH_RELEASE
  JAILBOX_E2E_REH_COMMIT  VSCodium REH build to smoke-test on Alpine.
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
        custom-user)  echo 24232 ;;
        uid-mismatch) echo 24233 ;;
        egress)       echo 24234 ;;
        *) die "unknown stage: $1" ;;
    esac
}

stage_reh_probe_port() {
    case "$1" in
        debian)       echo 25229 ;;
        alpine)       echo 25230 ;;
        fedora)       echo 25231 ;;
        custom-user)  echo 25232 ;;
        uid-mismatch) echo 25233 ;;
        egress)       echo 25234 ;;
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
    local remote_output remote_output_file remote_rc listening_on tunnel_pid=""

    # Mirrors the current VSCodium/Open Remote SSH server used in manual tests.
    # Keep these overridable so CI can follow VSCodium release bumps without
    # editing the test script first.
    local reh_release="${JAILBOX_E2E_REH_RELEASE:-1.116.02821}"
    local reh_commit="${JAILBOX_E2E_REH_COMMIT:-221e0a382c0be3a673a4e4cab0601344a0b3de3a}"

    remote_output_file="$(mktemp)"
    ssh -F "$config" -o ConnectTimeout=3 "$ctr" \
        "JAILBOX_E2E_REH_RELEASE='$reh_release' JAILBOX_E2E_REH_COMMIT='$reh_commit' bash -s" >"$remote_output_file" 2>&1 <<'REMOTE'
set -uo pipefail
echo "REH_RELEASE=$JAILBOX_E2E_REH_RELEASE"
echo "REH_COMMIT=$JAILBOX_E2E_REH_COMMIT"

SERVER_DATA_DIR="$HOME/.vscodium-server"
SERVER_DIR="$SERVER_DATA_DIR/bin/$JAILBOX_E2E_REH_COMMIT"
SERVER_SCRIPT="$SERVER_DIR/bin/codium-server"
SERVER_LOGFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.log"
SERVER_PIDFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.pid"
SERVER_TOKENFILE="$SERVER_DATA_DIR/.$JAILBOX_E2E_REH_COMMIT.token"

os_release_id="$(grep -i '^ID=' /etc/os-release 2>/dev/null | sed 's/^ID=//gi' | sed 's/"//g' || true)"
platform="linux"
if [[ "$os_release_id" == "alpine" ]]; then
    platform="alpine"
fi

arch="$(uname -m)"
case "$arch" in
    x86_64 | amd64) server_arch="x64" ;;
    aarch64 | arm64) server_arch="arm64" ;;
    *) echo "unsupported arch: $arch"; exit 1 ;;
esac

mkdir -p "$SERVER_DIR" "$SERVER_DATA_DIR" || {
    echo "REH_MKDIR_FAILED=$?"
    exit 1
}

echo "REH_SERVER_DIR=$SERVER_DIR"
if [[ ! -f "$SERVER_SCRIPT" ]]; then
    url="https://github.com/VSCodium/vscodium/releases/download/$JAILBOX_E2E_REH_RELEASE/vscodium-reh-${platform}-${server_arch}-$JAILBOX_E2E_REH_RELEASE.tar.gz"
    echo "REH_DOWNLOAD_URL=$url"
    tmp="$SERVER_DIR/vscode-server.tar.gz"
    if command -v curl >/dev/null 2>&1; then
        curl --retry 3 --connect-timeout 10 --max-time 120 --location --show-error --silent --output "$tmp" "$url"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "REH_DOWNLOAD_FAILED=$rc"
            exit 1
        fi
    else
        wget --tries=3 --timeout=10 --continue --no-verbose -O "$tmp" "$url"
        rc=$?
        if [[ "$rc" -ne 0 ]]; then
            echo "REH_DOWNLOAD_FAILED=$rc"
            exit 1
        fi
    fi
    echo "REH_DOWNLOAD_OK"
    tar -xf "$tmp" -C "$SERVER_DIR" --strip-components 1
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "REH_EXTRACT_FAILED=$rc"
        ls -lh "$tmp" 2>&1 || true
        exit 1
    fi
    echo "REH_EXTRACT_OK"
    rm -f "$tmp"
else
    echo "REH_SERVER_ALREADY_INSTALLED"
fi

if [[ ! -x "$SERVER_SCRIPT" ]]; then
    echo "REH_SERVER_SCRIPT_NOT_EXECUTABLE=$SERVER_SCRIPT"
    ls -la "$SERVER_DIR" "$SERVER_DIR/bin" 2>&1 || true
    exit 1
fi

if [[ -f "$SERVER_PIDFILE" ]]; then
    kill "$(cat "$SERVER_PIDFILE")" >/dev/null 2>&1 || true
fi
rm -f "$SERVER_LOGFILE" "$SERVER_TOKENFILE"
printf '%s\n' "jailbox-e2e-token" > "$SERVER_TOKENFILE"
chmod 600 "$SERVER_TOKENFILE"

echo "REH_STARTING=$SERVER_SCRIPT"
"$SERVER_SCRIPT" --start-server --host=127.0.0.1 --port=0 \
    --connection-token-file "$SERVER_TOKENFILE" \
    --telemetry-level off --enable-remote-auto-shutdown \
    --accept-server-license-terms > "$SERVER_LOGFILE" 2>&1 &
echo "$!" > "$SERVER_PIDFILE"
echo "REH_PID=$(cat "$SERVER_PIDFILE")"

for _ in $(seq 1 30); do
    listening_on="$(grep -E 'Extension host agent listening on .+' "$SERVER_LOGFILE" 2>/dev/null | tail -1 | sed 's/.*Extension host agent listening on //')"
    if [[ -n "$listening_on" ]]; then
        echo "LISTENING_ON=$listening_on"
        exit 0
    fi
    sleep 0.2
done

echo "REH_LISTENING_PORT_NOT_FOUND"
cat "$SERVER_LOGFILE" || true
echo "### process list"
ps -o pid,ppid,args -A | grep -E 'codium|node|server-main' | grep -v grep || true
echo "### server dir"
ls -la "$SERVER_DIR" "$SERVER_DIR/bin" 2>&1 || true
exit 1
REMOTE
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
# Minimal stub: verify jailbox called open_editor without SSH CLI options.
# The real SSH assertions run after jailbox exits, while the container is up.

setup_stub_editor() {
    cat > "$stub_dir/code" << 'STUB'
#!/bin/bash
set -euo pipefail

container=""
workspace=""
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
    elif [[ "$arg" == */jailbox.code-workspace ]]; then
        workspace="$arg"
    fi
    prev="$arg"
done

[[ -n "${JAILBOX_E2E_PROJECT:-}" ]] || { echo "stub: JAILBOX_E2E_PROJECT not set" >&2; exit 1; }
[[ -n "$user_data_dir" ]] || { echo "stub: no --user-data-dir argument received" >&2; exit 1; }
[[ -f "$user_data_dir/User/settings.json" ]] || { echo "stub: user-data settings missing" >&2; exit 1; }
grep -Fq '"remote.SSH.configFile":' "$user_data_dir/User/settings.json" || {
    echo "stub: user-data settings missing remote.SSH.configFile" >&2
    exit 1
}
if [[ -n "$workspace" ]]; then
    [[ -f "$workspace" ]] || { echo "stub: workspace missing: $workspace" >&2; exit 1; }
    grep -Fq '"remote.SSH.configFile":' "$workspace" || { echo "stub: workspace missing remote.SSH.configFile" >&2; exit 1; }
elif [[ -z "$container" ]]; then
    echo "stub: no ssh-remote+<container> or jailbox.code-workspace argument received" >&2
    exit 1
fi

echo "stub: editor called"
STUB
    chmod +x "$stub_dir/code"
    ln -sf "$stub_dir/code" "$stub_dir/codium"
}

# ── run_e2e_case ──────────────────────────────────────────────────────────────
# Designed to run inside a subshell. PASSED/FAILED are subshell-local.

run_e2e_case() {
    local stage="$1"
    local log_dir="$2"
    local dev_user="devuser"

    case "$stage" in
        custom-user) dev_user="appuser" ;;
    esac

    # Not declared local: EXIT trap fires after the function returns, at which
    # point local variables are out of scope.
    project_dir=""

    trap 'echo "$PASSED $FAILED" > "'"$log_dir"'/'"$stage"'.counts"
          if [[ -n "$project_dir" ]]; then
              (cd "$project_dir" && "'"$JAILBOX_DIR"'/jailbox" --clean 2>/dev/null || true)
              rm -rf "$project_dir"
          fi' EXIT

    echo ""
    echo "── e2e: $stage (user: $dev_user) ─────────────────────────────────────"

    project_dir="/tmp/jailbox-e2e-${stage}"
    rm -rf "$project_dir"
    mkdir -p "$project_dir"

    local dev_image
    dev_image=$(stage_test_image "$stage")

    cat > "$project_dir/jailbox.conf" << EOF
DEV_IMAGE=${dev_image}
DEV_USER=${dev_user}
REMOTE_PATH=/home/${dev_user}/project
EOF

    if [[ "$stage" == "egress" ]]; then
        printf 'EGRESS_ALLOW=("api.ipify.org")\n' >> "$project_dir/jailbox.conf"
    fi
    write_jailbox_workspace_config "$project_dir" "$(jailbox_container_name "$project_dir")" "/home/${dev_user}/project"

    export JAILBOX_E2E_PROJECT="$project_dir"

    # ── Phase 1: full jailbox pipeline ────────────────────────────────────────
    if (
        cd "$project_dir"
        PATH="$stub_dir:$PATH" "$JAILBOX_DIR/jailbox"
    ) 2>&1; then
        pass "pipeline (build → start → SSH wait → validation → editor stub)"
    else
        fail "pipeline failed"
        return 1
    fi

    # ── Phase 2: headless assertions (container still running) ────────────────
    local ssh_cfg
    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    local ctr
    ctr=$(jailbox_container_name "$project_dir")
    local forward_port reh_probe_port
    forward_port=$(stage_forward_port "$stage")
    reh_probe_port=$(stage_reh_probe_port "$stage")

    # Shell and tools
    assert_eq "login shell is bash" "bash" \
        "$(e2e_ssh "$ssh_cfg" "$ctr" "basename \"\$(grep -m1 '^${dev_user}:' /etc/passwd | cut -d: -f7)\"" || true)"
    assert_ssh "$ssh_cfg" "$ctr" ".bashrc sets PS1"     "grep -q PS1 ~/.bashrc"
    assert_ssh "$ssh_cfg" "$ctr" "bash available"       "command -v bash >/dev/null"
    assert_ssh "$ssh_cfg" "$ctr" "git available"        "git --version >/dev/null"
    assert_local_forwarding "$ssh_cfg" "$ctr" "$forward_port" "SSH local forwarding works"
    if [[ "$stage" == "alpine" ]]; then
        assert_vscodium_reh_probe "$ssh_cfg" "$ctr" "$reh_probe_port" "VSCodium REH reachable through OpenSSH tunnel"
    fi

    # Mounts
    assert_ssh "$ssh_cfg" "$ctr" "home writable" "test -w \"\$HOME\""
    assert_ssh "$ssh_cfg" "$ctr" "project mount writable" \
        "touch /home/${dev_user}/project/.e2e-test && rm /home/${dev_user}/project/.e2e-test"

    # Security
    assert_ssh_fails "$ssh_cfg" "$ctr" "rootfs is read-only"  "touch /etc/.e2e-test"
    assert_ssh       "$ssh_cfg" "$ctr" "no docker socket"     "! test -S /var/run/docker.sock"
    assert_ssh       "$ssh_cfg" "$ctr" "no podman socket"     "! test -S /run/podman/podman.sock"

    # Egress policy (only run for the egress stage)
    if [[ "$stage" == "egress" ]]; then
        local proxy_ctr="${ctr}-proxy"

        assert_ssh "$ssh_cfg" "$ctr" "HTTPS_PROXY is set in SSH session" \
            "[ -n \"\$HTTPS_PROXY\" ]"
        assert_ssh_fails "$ssh_cfg" "$ctr" "direct HTTP(S) bypassing proxy is blocked" \
            "curl --noproxy '*' --connect-timeout 5 --max-time 5 -fs https://example.com"
        assert_ssh_fails "$ssh_cfg" "$ctr" "raw TCP to external IP is blocked" \
            "timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/443' 2>/dev/null"
        assert_ssh "$ssh_cfg" "$ctr" "curl via proxy to allowed host (api.ipify.org) succeeds" \
            "curl -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org >/dev/null"
        assert_ssh_fails "$ssh_cfg" "$ctr" "curl via proxy to disallowed host fails" \
            "curl --connect-timeout 10 --max-time 10 -fs http://not-in-allowlist.example.org"
        assert_ssh_fails "$ssh_cfg" "$ctr" "proxy rejects CONNECT to non-443 port" \
            "curl --connect-timeout 5 --max-time 5 -fs https://api.ipify.org:8080/"

        # ── Proxy network diagnostics ─────────────────────────────────────────
        echo "  [diag] proxy env vars in SSH session:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "env | grep -i proxy || echo '(none)'" 2>/dev/null || true
        echo "  [diag] SetEnv lines in /run/sshd/sshd_config:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "grep -i setenv /run/sshd/sshd_config 2>/dev/null || echo '(none)'" 2>/dev/null || true
        echo "  [diag] proxy direct reach (wget api.ipify.org, bypassing tinyproxy):"
        podman exec "$proxy_ctr" wget -qO- --timeout=5 http://api.ipify.org 2>&1 || echo "(wget failed)"
        echo "  [diag] curl verbose via proxy (inside jailbox):"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "curl -v --connect-timeout 5 --max-time 10 https://api.ipify.org" 2>&1 || true
        echo "  [diag] tinyproxy logs:"
        podman logs "$proxy_ctr" 2>&1 || true
    fi
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
            die "$required_image not found — run tests/integration-images.sh first"
    done

    local log_dir
    log_dir="$JAILBOX_DIR/testlog/e2e-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$log_dir"
    stub_dir=$(mktemp -d)
    trap 'rm -rf "$stub_dir"' EXIT

    setup_stub_editor

    echo "jailbox e2e tests (parallel)"
    echo "Stages : ${stages[*]}"
    echo ""

    local -A stage_pids=()
    for stage in "${stages[@]}"; do
        printf "  ⏳ %s\n" "$stage"
        ( run_e2e_case "$stage" "$log_dir" ) > "$log_dir/${stage}.log" 2>&1 &
        stage_pids[$stage]=$!
    done
    echo ""

    local -A reported=()
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
                fi
                reported[$stage]=1
            elif ! kill -0 "${stage_pids[$stage]}" 2>/dev/null; then
                printf "  ❌ %-16s (crashed)\n" "$stage"
                reported[$stage]=1
            fi
        done
        [[ ${#reported[@]} -lt ${#stages[@]} ]] && sleep 0.3
    done
    echo ""

    for pid in "${stage_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

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
    echo "Full logs: $log_dir"
    if [[ "$total_failed" -gt 0 ]]; then
        echo "Failed stage logs:"
        for stage in "${stages[@]}"; do
            if [[ ! -f "$log_dir/${stage}.counts" ]]; then
                echo "  $log_dir/${stage}.log"
                continue
            fi
            read -r p f < "$log_dir/${stage}.counts"
            [[ "$f" -gt 0 ]] && echo "  $log_dir/${stage}.log"
        done
    fi
    [ $total_failed -eq 0 ] || exit 1
}

main "$@"
