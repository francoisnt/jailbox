#!/bin/bash
# Real public dispatch, child core processes, and shared attachment policy.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/convergence-fixture.sh
source "$ROOT/tests/lib/convergence-fixture.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$FIXTURE/home" FAKE_TRACE="$FIXTURE/editor-trace"
export JAILBOX_INOTIFY_MAX_USER_WATCHES_FILE="$FIXTURE/no-limit"
mkdir "$HOME"
for editor in code codium; do
    cp "$ROOT/tests/fixtures/editor-client/editor.sh" "$FIXTURE/bin/$editor"
    chmod 755 "$FIXTURE/bin/$editor"
done
for editor in code codium; do
    for name in "${!JAILBOX_CONFIG_EGRESS_ALLOW_@}"; do unset "$name"; done
    : > "$CONVERGENCE_LOG"
    printf 'DEV_IMAGE=localhost/convergence\nEDITOR=%s\nEGRESS_ALLOW=example.com\n' "$editor" > "$FIXTURE/project/jailbox.conf"
    # File validation and local init do not depend on the editor implementation;
    # exercise them once. Both editors retain bootstrap/policy integration below.
    if [[ "$editor" = code ]]; then
        # The public file validator must delegate to core with no runtime prerequisites.
        mkdir -p "$FIXTURE/local-bin"
        for tool in bash dirname readlink realpath env; do
            ln -sf "$(command -v "$tool")" "$FIXTURE/local-bin/$tool"
        done
        PATH="$FIXTURE/local-bin" launch --config jailbox.conf validate
        [[ ! -s "$CONVERGENCE_LOG" ]]
        printf 'DEV_IMAGE=selected\nEDITOR=code\n' > "$FIXTURE/project/selected.conf"
        PATH="$FIXTURE/local-bin" launch --config selected.conf validate
        printf 'DEV_IMAGE=selected\nREADONLY_PATHS=missing\n' > "$FIXTURE/project/selected.conf"
        if PATH="$FIXTURE/local-bin" launch --config selected.conf validate; then fail 'selected file was ignored'; fi
        rm "$FIXTURE/project/selected.conf"
        # Byte rejection must happen before Bash can turn poisoned input into a
        # valid launch or validation policy, on each public file-driven path.
        cp "$FIXTURE/project/jailbox.conf" "$FIXTURE/valid.conf"
        printf 'DEV_IMAGE=localhost/conver\0gence\n' > "$FIXTURE/project/jailbox.conf"
        for mode in editor headless validate; do
            args=()
            case $mode in headless) args=(--no-editor) ;; validate) args=(--config jailbox.conf validate) ;; esac
            : > "$FAKE_TRACE"
            if launch "${args[@]}" > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'NUL input accepted'; fi
            grep -q 'NUL byte' "$FIXTURE/error"
            [[ ! -s "$CONVERGENCE_LOG" && ! -s "$FAKE_TRACE" ]]
        done
        cp "$FIXTURE/valid.conf" "$FIXTURE/project/jailbox.conf"
    fi
    # Inventory must run before any lifecycle call, including reopening.
    if FAKE_INVENTORY_STATUS=42 launch > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'inventory failure accepted'; fi
    [[ ! -s "$CONVERGENCE_LOG" ]]
    : > "$FAKE_TRACE"
    JAILBOX_CONFIG_DEV_IMAGE=ignored-secret JAILBOX_EDITOR=invalid EDITOR=invalid launch > "$FIXTURE/out" 2> "$FIXTURE/error"
    grep -q JAILBOX_CONFIG_DEV_IMAGE "$FIXTURE/error"
    if grep -q ignored-secret "$FIXTURE/error"; then fail 'ignored value leaked'; fi
    [[ $(cat "$FAKE_TRACE") = "inventory:$editor"$'\n'"launch:$editor" ]]
    # The equivalent machine policy reaches connection-info, exec, and shell.
    export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
    export JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
    if [[ $editor == code ]]; then
        hosts=(example.com update.code.visualstudio.com vscode.download.prss.microsoft.com main.vscode-cdn.net vo.msecnd.net)
    else
        hosts=(example.com github.com githubusercontent.com)
    fi
    for name in "${!JAILBOX_CONFIG_EGRESS_ALLOW_@}"; do unset "$name"; done
    for index in "${!hosts[@]}"; do export "JAILBOX_CONFIG_EGRESS_ALLOW_$index=${hosts[index]}"; done
    # Matching independently specified machine policy proves the digest includes
    # all bootstrap hosts; exact filter bytes prove rendering uses that same set.
    printf '%s\n' "${hosts[@]}" | LC_ALL=C sort -u | sed 's/\./\\./g' | awk '{print "^" $0 "$"; print "\\." $0 "$"}' > "$FIXTURE/filter.expected"
    cmp "$FIXTURE/filter.expected" "$XDG_STATE_HOME/jailbox/projects/$HASH/tinyproxy-filter"
    grep -Fq -- "$FIXTURE/project/jailbox.conf:/home/jailbox/project/jailbox.conf:Z,ro" "$CONVERGENCE_LOG"
    launch connection-info > "$FIXTURE/records"
    export CONVERGENCE_EXEC_HELPER="$FIXTURE/exec-helper"
    # shellcheck disable=SC2016 # The decoder expands its fixture directory.
    sed 's|^cd /home/jailbox/project |cd "$CONVERGENCE_ENGINE" |' "$ROOT/src/container/runtime/bin/jailbox-exec-argv" > "$CONVERGENCE_EXEC_HELPER"
    # exec.sh owns exhaustive argv/stdin fidelity. Here the contract is that
    # file-derived bootstrap policy is accepted by each machine consumer.
    launch exec printf '%s' attached > "$FIXTURE/actual"
    [[ $(cat "$FIXTURE/actual") = attached ]]
    python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$FIXTURE/project" --output "$FIXTURE/shell" -- "$ROOT/src/jailbox" shell
    # Include editor hosts explicitly, reorder and repeat: both paths now agree.
    host_csv=
    for host in "${hosts[@]}"; do host_csv="$host${host_csv:+,$host_csv}"; done
    printf 'DEV_IMAGE=localhost/convergence\nEDITOR=%s\nEGRESS_ALLOW=%s,example.com\n' "$editor" "$host_csv" > "$FIXTURE/project/jailbox.conf"
    : > "$CONVERGENCE_LOG"
    for index in "${!hosts[@]}"; do
        export "JAILBOX_CONFIG_EGRESS_ALLOW_$index=${hosts[${#hosts[@]}-1-index]}"
    done
    export "JAILBOX_CONFIG_EGRESS_ALLOW_${#hosts[@]}=example.com"
    launch up > "$FIXTURE/out" 2> "$FIXTURE/error"
    launch --no-editor > "$FIXTURE/out" 2> "$FIXTURE/error"
    launch > "$FIXTURE/out" 2> "$FIXTURE/error"
    if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then fail 'equivalent policy recreated resources'; fi
    cmp "$FIXTURE/filter.expected" "$XDG_STATE_HOME/jailbox/projects/$HASH/tinyproxy-filter"
    before=$(snapshot)
    : > "$CONVERGENCE_LOG"
    export "JAILBOX_CONFIG_EGRESS_ALLOW_${#hosts[@]}=changed.example.com"
    for command in connection-info exec; do
        args=(); [[ "$command" != exec ]] || args=(true)
        if launch "$command" "${args[@]}" > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'changed policy attached'; fi
        grep -q 'jailbox stop' "$FIXTURE/error"
    done
    python3 "$ROOT/tests/lib/shell-terminal.py" --cwd "$FIXTURE/project" --output "$FIXTURE/shell" --expect refuse -- "$ROOT/src/jailbox" shell
    assert_no_mutation
    # File change refuses before editor launch; the frontend never repairs state.
    printf 'DEV_IMAGE=localhost/convergence\nEDITOR=code\nEGRESS_ALLOW=changed.example.com\n' > "$FIXTURE/project/jailbox.conf"
    : > "$FAKE_TRACE"
    if launch > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'changed file policy launched'; fi
    [[ $(cat "$FAKE_TRACE") = 'inventory:code' ]]
    assert_no_mutation
    if [[ "$editor" = code ]]; then
        # Init is local even with running/stopped containers, networks, or only a home.
        for state in running stopped networks home; do
            case $state in
                stopped) for resource in "$PREFIX" "$PREFIX-proxy"; do podman stop "$resource" >/dev/null; done ;;
                networks) for resource in "$PREFIX" "$PREFIX-proxy"; do podman rm -f "$resource" >/dev/null; done ;;
                home) launch stop >/dev/null ;;
            esac
            before=$(snapshot)
            : > "$CONVERGENCE_LOG"
            rm "$FIXTURE/project/jailbox.conf"
            launch init > "$FIXTURE/out"
            assert_no_mutation
        done
    fi
    launch --clean >/dev/null
    unset JAILBOX_CONFIG_READONLY_PATHS_0
done
printf 'PASS: public file validation, editor sequencing, equivalent reuse, and machine attachment\n'

# Config selection participates in both the digest gate and mount arguments.
for name in "${!JAILBOX_CONFIG_@}"; do unset "$name"; done
printf 'DEV_IMAGE=localhost/convergence\n' > "$FIXTURE/project/jailbox.conf"
cp "$FIXTURE/project/jailbox.conf" "$FIXTURE/project/selected.conf"
cp "$FIXTURE/project/jailbox.conf" "$FIXTURE/external.conf"
launch --no-editor > "$FIXTURE/out"
before=$(snapshot)
: > "$CONVERGENCE_LOG"
if launch --config selected.conf --no-editor > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'new anchor reused'; fi
grep -q 'jailbox stop' "$FIXTURE/error"
assert_no_mutation
launch --config "$FIXTURE/external.conf" --no-editor > "$FIXTURE/out"
if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then fail 'external selection changed policy'; fi
launch stop > "$FIXTURE/out"
: > "$CONVERGENCE_LOG"
launch --config selected.conf --no-editor > "$FIXTURE/out"
for anchor in jailbox.conf selected.conf; do
    grep -Fq -- "$FIXTURE/project/$anchor:/home/jailbox/project/$anchor:Z,ro" "$CONVERGENCE_LOG"
done
export JAILBOX_CONFIG_DEV_IMAGE=localhost/convergence
export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf JAILBOX_CONFIG_READONLY_PATHS_1=selected.conf
launch connection-info > "$FIXTURE/records"
unset JAILBOX_CONFIG_READONLY_PATHS_1
before=$(snapshot)
: > "$CONVERGENCE_LOG"
if launch connection-info > "$FIXTURE/out" 2> "$FIXTURE/error"; then fail 'anchor absent from digest'; fi
assert_no_mutation
# Prelisting an anchor makes changing the selected config policy-equivalent.
printf 'READONLY_PATHS=jailbox.conf,selected.conf\n' >> "$FIXTURE/project/jailbox.conf"
launch --no-editor > "$FIXTURE/out"
if grep -Eq '^(run|start|stop|rm|network create|volume create)' "$CONVERGENCE_LOG"; then fail 'prelisted anchor recreated resources'; fi
printf 'PASS: config anchors affect digest and mounts; equivalent selections reuse\n'
