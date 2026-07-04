#!/bin/bash
# Editor smoke test for jailbox.
#
# For each stage: creates a temporary VS Code/VSCodium workspace fixture,
# launches the workspace through jailbox, waits for an editor window to attach
# to the Remote SSH server, runs the validation probe through the generated
# SSH target, and verifies the proof file from the host. Then installs the
# proof extension (fixtures/proof-extension/) into the remote editor server
# and verifies the remote extension host activates it and executes a shell
# task in the mounted workspace with exit code 0 — i.e. a user opening their
# repo through jailbox gets an operational editor. The task is taken from
# .vscode/tasks.json when the editor discovers it in time, otherwise defined
# via the vscode.tasks API; which path was used is recorded as diagnostics
# and is deliberately not part of the pass/fail gate.
#
# Prerequisites: run tests/integration/wrapper-images.sh first to build the jailbox-test-* images.
#
# Usage: tests/e2e/editor-smoke.sh [stage...]
# Env:   JAILBOX_EDITOR_TIMEOUT seconds to wait for editor attach (default: 45)
#        JAILBOX_KEEP_FAILED=1 keeps failed temp projects/containers for diagnosis
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=host/project-id.sh
source "$JAILBOX_DIR/host/project-id.sh"

ALL_STAGES=(debian alpine fedora egress)
VSCODE_STAGES=(debian fedora egress)
PROOF_FILE=".jailbox-editor-proof"
# Marker/label values must match tests/e2e/fixtures/proof-extension/extension.js.
EXT_ACTIVATION_MARKER=".jailbox-editor-ext-activated"
EXT_TASK_RESULT=".jailbox-editor-task-result"
TASK_LABEL="jailbox: validate remote session"
EDITOR_TIMEOUT="${JAILBOX_EDITOR_TIMEOUT:-45}"

PASSED=0
FAILED=0
LOG_DIR=""
RUN_LOG=""
PROOF_VSIX=""

# ── helpers ───────────────────────────────────────────────────────────────────

die()   { echo "Error: $*" >&2; exit 1; }
pass()  { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail()  { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

jailbox_container_name() {
    printf 'jailbox-%s\n' "$(jailbox_project_hash_for_path "$1")"
}

jailbox_ssh_config() {
    local hash

    hash=$(jailbox_project_hash_for_path "$1")
    printf '%s/jailbox/projects/%s/ssh_config\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$hash"
}

jailbox_editor_user_data() {
    local project_dir="$1"
    local hash

    hash=$(jailbox_project_hash_for_path "$project_dir")
    printf '%s/jailbox/editor-profiles/%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$hash"
}

stage_test_image() {
    case "$1" in
        egress) echo "jailbox-test-debian" ;;
        *)      echo "jailbox-test-$1" ;;
    esac
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [stage...]

Launch VSCodium/VS Code through jailbox, verify a Remote SSH probe creates
$PROOF_FILE in a temporary workspace, then verify the remote extension host
activates the jailbox proof extension and executes a shell task in the
mounted workspace with exit code 0. tasks.json discovery is diagnostic-only.

Stages: ${ALL_STAGES[*]}
Default: all stages in order.
VS Code default: ${VSCODE_STAGES[*]} (VS Code Remote SSH does not support Alpine SSH hosts).

Requires: podman, ssh, ssh-keygen, python3, VSCodium or VS Code CLI.
Run tests/integration/wrapper-images.sh first to build the jailbox-test-* images.

Environment:
  JAILBOX_EDITOR_TIMEOUT  Seconds to wait for editor attach (default: 45)
  JAILBOX_EDITOR          Editor CLI to test: codium or code (default: auto)
  JAILBOX_KEEP_FAILED=1   Keep failed temp workspaces/containers for diagnosis
EOF
}

setup_logging() {
    LOG_DIR="$JAILBOX_DIR/testlog/editor-$(date +%Y%m%d-%H%M%S)-$$"
    RUN_LOG="$LOG_DIR/editor-smoke.log"
    mkdir -p "$LOG_DIR"
}

log_run() {
    printf '%s\n' "$*" | tee -a "$RUN_LOG"
}

run_stage_logged() {
    local stage="$1"
    local idx="$2"
    local total="$3"
    local stage_log="$LOG_DIR/${stage}.log"

    printf 'LOG %s %s\n' "$stage" "$stage_log" >> "$RUN_LOG"
    if run_stage "$stage" "$idx" "$total" > >(tee "$stage_log") 2>&1; then
        return 0
    fi

    return 1
}

editor_bin() {
    case "${JAILBOX_EDITOR:-}" in
        "")
            ;;
        codium|code)
            command -v "$JAILBOX_EDITOR"
            return $?
            ;;
        *)
            return 1
            ;;
    esac

    if command -v codium >/dev/null 2>&1; then
        command -v codium
    elif command -v code >/dev/null 2>&1; then
        command -v code
    else
        return 1
    fi
}

editor_name() {
    local bin

    bin=$(editor_bin) || return 1
    case "$(basename "$bin")" in
        codium) echo "codium" ;;
        code)   echo "code" ;;
        *)      basename "$bin" ;;
    esac
}

editor_server_dirs() {
    case "$(editor_name)" in
        codium)
            printf '%s\n' ".vscodium-server" ".vscode-server"
            ;;
        code)
            printf '%s\n' ".vscode-server" ".vscodium-server"
            ;;
        *)
            printf '%s\n' ".vscode-server" ".vscodium-server"
            ;;
    esac
}

default_editor_stages() {
    if [[ "$(editor_name)" == "code" ]]; then
        printf '%s\n' "${VSCODE_STAGES[@]}"
    else
        printf '%s\n' "${ALL_STAGES[@]}"
    fi
}

have_display() {
    [[ "$(uname -s)" == "Darwin" ]] && return 0
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

write_fixture() {
    local project_dir="$1"
    local stage="$2"
    local run_id="$3"
    local dev_image

    dev_image=$(stage_test_image "$stage")

    mkdir -p "$project_dir/.vscode"
    cat > "$project_dir/jailbox.conf" <<EOF
DEV_IMAGE=${dev_image}
EOF
    if [[ "$stage" == "egress" ]]; then
        printf 'EGRESS_ALLOW=api.ipify.org\n' >> "$project_dir/jailbox.conf"
    fi

    cat > "$project_dir/README.txt" <<EOF
jailbox editor smoke fixture for $stage
EOF
    printf '%s\n' "$run_id" > "$project_dir/.jailbox-editor-run-id"

    cp "$SCRIPT_DIR/editor-validate.sh" "$project_dir/.vscode/jailbox-validate.sh"
    chmod +x "$project_dir/.vscode/jailbox-validate.sh"

    # Executed by the proof extension via the vscode.tasks API; no
    # runOn:folderOpen, so nothing races the editor's task discovery.
    # Whether the editor discovers this file is diagnostic-only — the
    # extension defines an equivalent task itself if discovery times out.
    cat > "$project_dir/.vscode/tasks.json" <<EOF
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "$TASK_LABEL",
      "type": "shell",
      "command": "bash .vscode/jailbox-validate.sh",
      "options": { "cwd": "\${workspaceFolder}" },
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": []
    }
  ]
}
EOF
}

close_editor_workspace() {
    local project_dir="$1"
    local ctr="$2"
    local bin user_data

    bin=$(editor_bin) || return 0
    user_data=$(jailbox_editor_user_data "$project_dir")

    "$bin" --user-data-dir "$user_data" \
        --reuse-window \
        --remote "ssh-remote+$ctr" \
        /home/jailbox/project \
        --command workbench.action.closeWindow >/dev/null 2>&1 || true
}

terminate_editor_profile() {
    local project_dir="$1"
    local user_data pid

    user_data=$(jailbox_editor_user_data "$project_dir")

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$$" ]] && continue
        kill "$pid" >/dev/null 2>&1 || true
    done < <(
        ps -eo pid=,args= |
            awk -v user_data="$user_data" '
                index($0, "--user-data-dir " user_data) ||
                index($0, "--user-data-dir=" user_data) {
                    print $1
                }
            '
    )
}

cleanup_editor_workspace() {
    local project_dir="$1"
    local ctr="$2"

    close_editor_workspace "$project_dir" "$ctr"
    sleep 0.5
    terminate_editor_profile "$project_dir"
}

prune_stale_jailbox_resources() {
    local ctrs nets

    ctrs=$(podman ps -aq --filter 'name=^jailbox-' 2>/dev/null || true)
    nets=$(podman network ls -q --filter 'name=^jailbox-' 2>/dev/null || true)

    if [[ -n "$ctrs" || -n "$nets" ]]; then
        echo "Pruning stale jailbox containers/networks from a previous run..."
        if [[ -n "$ctrs" ]]; then
            printf '%s\n' "$ctrs" | xargs podman rm -f >/dev/null 2>&1 || true
        fi
        if [[ -n "$nets" ]]; then
            printf '%s\n' "$nets" | xargs podman network rm >/dev/null 2>&1 || true
        fi
    fi
}

wait_for_remote_editor_ready() {
    local project_dir="$1"
    local ctr="$2"
    local ssh_cfg deadline

    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    deadline=$((SECONDS + EDITOR_TIMEOUT))
    while (( SECONDS < deadline )); do
        # "Launched Extension Host Process" is logged only once an editor
        # window has attached to the remote server; "Extension host agent
        # started" merely means the server booted, with no window connected.
        # Current VS Code stores server logs under
        # .vscode-server/cli/servers/Stable-*/server/..., while older
        # VS Code/VSCodium builds used .*-server/bin/*/*.log.
        if ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" 'bash -s' <<'REMOTE' 2>/dev/null
for root in "$HOME/.vscodium-server" "$HOME/.vscode-server"; do
    [ -d "$root" ] || continue
    if find "$root" -maxdepth 8 -type f \( -name '*.log' -o -name 'log.txt' \) -exec grep -q 'Launched Extension Host Process' {} \; -print -quit |
        grep -q .; then
        exit 0
    fi
done
exit 1
REMOTE
        then
            return 0
        fi
        sleep 1
    done

    return 1
}

run_remote_validation_probe() {
    local project_dir="$1"
    local ctr="$2"
    local ssh_cfg

    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
        'cd /home/jailbox/project && bash .vscode/jailbox-validate.sh'
}

build_proof_vsix() {
    local out="$1"
    local src="$SCRIPT_DIR/fixtures/proof-extension"

    python3 - "$src" "$out" <<'PY'
import pathlib
import sys
import zipfile

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

manifest = """<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="jailbox-editor-proof" Version="0.0.1" Publisher="jailbox"/>
    <DisplayName>jailbox editor proof</DisplayName>
    <Description>jailbox e2e instrumentation extension</Description>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
"""

content_types = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
"""

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", content_types)
    z.writestr("extension.vsixmanifest", manifest)
    for name in ("package.json", "extension.js"):
        z.write(src / name, f"extension/{name}")
PY
}

# Installs the proof extension through the remote server's own CLI so it does
# the extensions.json bookkeeping, instead of us hand-writing internal state.
install_proof_extension() {
    local project_dir="$1"
    local ctr="$2"
    local ssh_cfg

    ssh_cfg=$(jailbox_ssh_config "$project_dir")

    ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
        'cat > /tmp/jailbox-editor-proof.vsix' < "$PROOF_VSIX" || return 1

    ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" 'bash -s' <<'REMOTE' 2>&1 | sed 's/^/    /'
set -eu
server_bin=""
for candidate in "$HOME/.vscodium-server/bin"/*/bin/codium-server \
                 "$HOME/.vscode-server/bin"/*/bin/code-server \
                 "$HOME/.vscodium-server/cli/servers"/*/server/bin/codium-server \
                 "$HOME/.vscode-server/cli/servers"/*/server/bin/code-server; do
    if [ -x "$candidate" ]; then
        server_bin="$candidate"
        break
    fi
done
[ -n "$server_bin" ] || { echo "no remote editor server CLI found" >&2; exit 1; }
"$server_bin" --install-extension /tmp/jailbox-editor-proof.vsix --force
REMOTE
}

# The running extension host predates the install, so reload the window until
# the extension's activation marker appears in the workspace. The reload
# command is fire-and-forget CLI IPC, but unlike the old task trigger it
# targets an always-registered core command and we retry against a hard
# acknowledgment (the marker file), so dropped deliveries self-heal.
activate_proof_extension() {
    local project_dir="$1"
    local ctr="$2"
    local bin user_data marker deadline last_reload

    bin=$(editor_bin) || return 1
    user_data=$(jailbox_editor_user_data "$project_dir")
    marker="$project_dir/$EXT_ACTIVATION_MARKER"
    deadline=$((SECONDS + EDITOR_TIMEOUT))
    last_reload=-10

    while (( SECONDS < deadline )); do
        [[ -f "$marker" ]] && return 0
        if (( SECONDS - last_reload >= 5 )); then
            "$bin" --user-data-dir "$user_data" \
                --reuse-window \
                --remote "ssh-remote+$ctr" \
                /home/jailbox/project \
                --command workbench.action.reloadWindow >/dev/null 2>&1 || true
            last_reload=$SECONDS
        fi
        sleep 1
    done

    [[ -f "$marker" ]]
}

wait_for_task_result() {
    local project_dir="$1"
    local result="$project_dir/$EXT_TASK_RESULT"
    local deadline

    # The extension spends up to 45s on tasks.json discovery before falling
    # back to a synthesized task, then runs the task; allow for both.
    deadline=$((SECONDS + EDITOR_TIMEOUT + 60))
    while (( SECONDS < deadline )); do
        [[ -f "$result" ]] && return 0
        sleep 1
    done

    [[ -f "$result" ]]
}

validate_task_result() {
    local project_dir="$1"
    local run_id="$2"
    local result="$project_dir/$EXT_TASK_RESULT"
    local rc=0

    assert_proof_contains "$result" "run_id=$run_id" "task result belongs to this test run" || rc=1
    assert_proof_contains "$result" "task_exit_code=0" "editor executed a shell task in the workspace (exit 0)" || rc=1

    # tasks.json discovery is editor-internal and diagnostic-only: the gate
    # asserts the editor can execute in the repo, not workbench task discovery.
    if ! grep -Fqx "task_source=workspace" "$result"; then
        echo "  note: tasks.json discovery timed out; the task was defined via the API instead"
    fi

    echo "  Task result:"
    sed 's/^/    /' "$result"

    return "$rc"
}

assert_proof_contains() {
    local proof_path="$1"
    local needle="$2"
    local desc="$3"

    if grep -Fqx "$needle" "$proof_path"; then
        pass "$desc"
        return 0
    else
        fail "$desc"
        return 1
    fi
}

validate_proof() {
    local project_dir="$1"
    local stage="$2"
    local run_id="$3"
    local proof_path
    local rc=0

    proof_path="$project_dir/$PROOF_FILE"

    if [[ -f "$proof_path" && ! -L "$proof_path" ]]; then
        pass "proof file exists in temp workspace"
    else
        fail "proof file exists in temp workspace"
        return 1
    fi

    assert_proof_contains "$proof_path" "run_id=$run_id" "proof file belongs to this test run" || rc=1
    assert_proof_contains "$proof_path" "whoami=jailbox" "probe ran as jailbox user" || rc=1
    assert_proof_contains "$proof_path" "authorized_keys=present" "sshd authorized_keys visible in container" || rc=1
    assert_proof_contains "$proof_path" "workspace_writable=yes" "remote workspace is writable" || rc=1
    assert_proof_contains "$proof_path" "pwd=/home/jailbox/project" "probe cwd is the mounted remote workspace" || rc=1

    if [[ "$stage" == "egress" ]]; then
        assert_proof_contains "$proof_path" "proxy_configured=yes" "proxy env visible when EGRESS_ALLOW is configured" || rc=1
    fi

    if [[ "$rc" -ne 0 ]]; then
        echo "  Proof file:"
        sed 's/^/    /' "$proof_path"
    fi

    return "$rc"
}

collect_failure_diagnostics() {
    local stage="$1"
    local project_dir="$2"
    local ctr="$3"
    local proof_path ssh_cfg server_dir find_expr proxy_ctr user_data

    proof_path="$project_dir/$PROOF_FILE"
    ssh_cfg=$(jailbox_ssh_config "$project_dir")
    proxy_ctr="${ctr}-proxy"
    user_data=$(jailbox_editor_user_data "$project_dir")
    find_expr=""
    while read -r server_dir; do
        [[ -n "$server_dir" ]] || continue
        find_expr="${find_expr:+$find_expr -o }-path '/home/jailbox/${server_dir}/*'"
    done < <(editor_server_dirs)

    echo ""
    echo "  Diagnostics for failed stage: $stage"
    echo "  Project dir: $project_dir"
    echo "  Container:   $ctr"
    echo "  SSH config:  $ssh_cfg"
    if [[ -f "$project_dir/.jailbox-editor-run-id" ]]; then
        echo "  Run id:      $(cat "$project_dir/.jailbox-editor-run-id")"
    fi
    echo ""

    if [[ -f "$proof_path" ]]; then
        echo "  Proof file:"
        sed 's/^/    /' "$proof_path"
    else
        echo "  Proof file was not created: $proof_path"
    fi

    echo ""
    echo "  Validation fixture:"
    sed 's/^/    /' "$project_dir/.vscode/jailbox-validate.sh" || true

    echo ""
    echo "  Task fixture:"
    sed 's/^/    /' "$project_dir/.vscode/tasks.json" || true

    local artifact
    for artifact in "$EXT_ACTIVATION_MARKER" "$EXT_TASK_RESULT"; do
        echo ""
        if [[ -f "$project_dir/$artifact" ]]; then
            echo "  Extension artifact $artifact:"
            sed 's/^/    /' "$project_dir/$artifact"
        else
            echo "  Extension artifact $artifact: (missing)"
        fi
    done

    echo ""
    echo "  Host editor profile logs:"
    echo "    Profile: $user_data"
    if [[ -d "$user_data/logs" ]]; then
        find "$user_data/logs" -maxdepth 5 -type f \
            \( -name '*.log' -o -name 'exthost*.txt' -o -name 'remoteagent*.txt' \) \
            -print -exec sh -c 'echo --- "$1"; tail -160 "$1"' sh {} \; \
            2>&1 | sed 's/^/    /' || true
    else
        echo "    (missing: $user_data/logs)"
    fi

    echo ""
    echo "  Host editor profile tree:"
    if [[ -d "$user_data" ]]; then
        find "$user_data" -maxdepth 4 -print | sed -n '1,200p' | sed 's/^/    /' || true
    else
        echo "    (missing: $user_data)"
    fi

    echo ""
    echo "  Host editor processes:"
    ps -eo pid=,ppid=,args= |
        awk '/(^|[ /])(codium|code)( |$)|open-remote-ssh|remote-ssh/ { print }' |
        sed 's/^/    /' || true

    if [[ -f "$ssh_cfg" ]]; then
        echo ""
        echo "  Remote workspace listing:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "pwd; ls -la /home/jailbox/project; printf 'run_id_file='; cat /home/jailbox/project/.jailbox-editor-run-id 2>/dev/null || true; env | grep -E '^(HTTP|HTTPS|NO)_PROXY=' || true" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Managed downloader proxy blocks:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "for f in \"\$HOME/.curlrc\" \"\$HOME/.wgetrc\"; do echo --- \$f; if [ -f \"\$f\" ]; then sed -n '/# >>> jailbox managed proxy >>>/,/# <<< jailbox managed proxy <<</p' \"\$f\"; else echo '(missing)'; fi; done" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Remote editor/server processes:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "ps -o pid,ppid,args -A | grep -E 'codium|code|node|extension|server' | grep -v grep || true" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Editor server directories:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "for d in /home/jailbox/.vscode-server /home/jailbox/.vscodium-server; do echo --- \$d; if [ -e \"\$d\" ]; then find \"\$d\" -maxdepth 3 -print | sed -n '1,120p'; else echo '(missing)'; fi; done" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  Remote Machine settings:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "for d in .vscodium-server .vscode-server; do f=\"\$HOME/\$d/data/Machine/settings.json\"; echo --- \$f; if [ -f \"\$f\" ]; then cat \"\$f\"; else echo '(missing)'; fi; done" \
            2>&1 | sed 's/^/    /' || true

        echo ""
        echo "  VS Code/VSCodium server logs:"
        ssh -F "$ssh_cfg" -o ConnectTimeout=3 "$ctr" \
            "find /home/jailbox -maxdepth 8 \\( $find_expr \\) -type f \\( -name '*.log' -o -name 'log.txt' \\) -print -exec sh -c 'echo --- \$1; tail -160 \"\$1\"' sh {} \\;" \
            2>&1 | sed 's/^/    /' || true
    fi

    if [[ "$stage" == "egress" ]]; then
        echo ""
        echo "  Egress proxy logs:"
        podman logs "$proxy_ctr" 2>&1 | tail -200 | sed 's/^/    /' || true
    fi
}

cleanup_stage() {
    local project_dir="$1"

    if [[ -n "$project_dir" ]]; then
        if (
            cd "$project_dir"
            "$JAILBOX_DIR/jailbox" --clean 2>/dev/null
        ); then
            :
        fi
        rm -rf "$project_dir"
    fi
}

run_stage() {
    local stage="$1"
    local idx="$2"
    local total="$3"
    local proof_path run_id rc

    # Not declared local: the EXIT trap fires after this function returns, at
    # which point local variables are out of scope.
    project_dir=""
    ctr=""
    editor_opened=0
    rc=0

    trap '
        if [[ -n "$project_dir" ]]; then
            [[ "$editor_opened" -eq 1 ]] && \
                cleanup_editor_workspace "$project_dir" "$ctr" 2>/dev/null || true
            cleanup_stage "$project_dir" 2>/dev/null || true
            project_dir=""
        fi
    ' EXIT

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  Stage %d/%d  ·  %s\n" "$idx" "$total" "$stage"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    project_dir=$(mktemp -d "/tmp/jailbox-editor-${stage}.XXXXXX")
    ctr=$(jailbox_container_name "$project_dir")
    proof_path="$project_dir/$PROOF_FILE"
    run_id="$(date +%s)-$$-$stage"

    write_fixture "$project_dir" "$stage" "$run_id"

    if (
        cd "$project_dir"
        JAILBOX_EDITOR_SMOKE_TEST_SETTINGS=1 "$JAILBOX_DIR/jailbox"
    ) 2>&1; then
        pass "jailbox launched editor workspace"
        editor_opened=1
    else
        fail "jailbox launched editor workspace"
        rc=1
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Waiting up to ${EDITOR_TIMEOUT}s for an editor window to attach to the remote..."
        if wait_for_remote_editor_ready "$project_dir" "$ctr"; then
            pass "editor window attached to remote (extension host launched)"
        else
            fail "editor window attached to remote (extension host launched)"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Running validation probe through generated SSH target..."
        if run_remote_validation_probe "$project_dir" "$ctr"; then
            pass "remote validation probe completed"
        else
            fail "remote validation probe completed"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        if [[ -f "$proof_path" ]]; then
            pass "proof file was created by remote validation probe"
        else
            fail "proof file was created by remote validation probe"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        validate_proof "$project_dir" "$stage" "$run_id" || rc=1
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Installing proof extension into remote editor server..."
        if install_proof_extension "$project_dir" "$ctr"; then
            pass "proof extension installed in remote editor server"
        else
            fail "proof extension installed in remote editor server"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Reloading editor window until proof extension activates (up to ${EDITOR_TIMEOUT}s)..."
        if activate_proof_extension "$project_dir" "$ctr"; then
            pass "proof extension activated in remote extension host"
        else
            fail "proof extension activated in remote extension host"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        echo "  Waiting up to $((EDITOR_TIMEOUT + 60))s for extension-run task result..."
        if wait_for_task_result "$project_dir"; then
            pass "extension reported a task result"
        else
            fail "extension reported a task result"
            rc=1
        fi
    fi

    if [[ "$rc" -eq 0 ]]; then
        validate_task_result "$project_dir" "$run_id" || rc=1
    fi

    if [[ "$rc" -ne 0 ]]; then
        collect_failure_diagnostics "$stage" "$project_dir" "$ctr"
        if [[ "$editor_opened" -eq 1 ]]; then
            cleanup_editor_workspace "$project_dir" "$ctr"
        fi
        if [[ "${JAILBOX_KEEP_FAILED:-}" == "1" ]]; then
            echo ""
            echo "  Keeping failed workspace and container because JAILBOX_KEEP_FAILED=1"
            echo "  Workspace: $project_dir"
            return 1
        fi
    fi

    if [[ "$editor_opened" -eq 1 ]]; then
        cleanup_editor_workspace "$project_dir" "$ctr"
    fi
    cleanup_stage "$project_dir"
    project_dir=""  # disarm the EXIT trap — cleanup already done
    return "$rc"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
    fi

    command -v podman     >/dev/null 2>&1 || die "podman is required"
    command -v ssh        >/dev/null 2>&1 || die "ssh is required"
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required"
    command -v python3    >/dev/null 2>&1 || die "python3 is required (packages the proof extension vsix)"
    editor_bin >/dev/null || die "neither 'codium' nor 'code' was found in PATH"
    have_display || die "no graphical display session found; run with tests/run --core-tests on headless hosts"
    [[ "$EDITOR_TIMEOUT" =~ ^[0-9]+$ ]] || die "JAILBOX_EDITOR_TIMEOUT must be a positive integer"
    [[ "$EDITOR_TIMEOUT" -gt 0 ]] || die "JAILBOX_EDITOR_TIMEOUT must be greater than zero"

    local stages=("$@")
    if [[ ${#stages[@]} -eq 0 ]]; then
        stages=()
        while IFS= read -r stage; do
            stages+=("$stage")
        done < <(default_editor_stages)
    fi

    for s in "${stages[@]}"; do
        local valid=0
        for a in "${ALL_STAGES[@]}"; do
            [[ "$s" == "$a" ]] && valid=1 && break
        done
        [[ "$valid" -eq 1 ]] || die "unknown stage '$s'. Valid: ${ALL_STAGES[*]}"
        if [[ "$(editor_name)" == "code" && "$s" == "alpine" ]]; then
            die "VS Code Remote SSH does not support Alpine SSH hosts; use codium to test the alpine stage"
        fi
    done

    local required_image
    for stage in "${stages[@]}"; do
        required_image=$(stage_test_image "$stage")
        podman image exists "$required_image" 2>/dev/null || \
            die "$required_image not found - run tests/integration/wrapper-images.sh first"
    done

    prune_stale_jailbox_resources
    setup_logging

    PROOF_VSIX="$LOG_DIR/jailbox-editor-proof.vsix"
    build_proof_vsix "$PROOF_VSIX" || die "failed to package the proof extension vsix"

    log_run "jailbox editor smoke test"
    log_run "Stages : ${stages[*]}"
    log_run "Timeout: ${EDITOR_TIMEOUT}s"
    log_run "Editor : $(editor_name)"
    log_run "Logs   : $LOG_DIR"
    log_run ""
    log_run "This test opens a graphical editor window and automates validation after launch."
    log_run ""

    local total=${#stages[@]}
    local idx=0
    local failed_stages=()

    for stage in "${stages[@]}"; do
        idx=$((idx + 1))
        if run_stage_logged "$stage" "$idx" "$total"; then
            printf 'PASS %s\n' "$stage" >> "$RUN_LOG"
        else
            printf 'FAIL %s\n' "$stage" >> "$RUN_LOG"
            failed_stages+=("$stage")
        fi
    done

    log_run ""
    log_run "──────────────────────────────────────────────────────────────────────"
    log_run "Results: $PASSED passed, $FAILED failed"
    if [[ ${#failed_stages[@]} -gt 0 ]]; then
        log_run "Failed stages: ${failed_stages[*]}"
    fi
    log_run "Full logs: $LOG_DIR"

    [[ "$FAILED" -eq 0 ]]
}

main "$@"
