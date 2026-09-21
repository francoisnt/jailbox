#!/bin/bash
# Integrated editor assertions; core readiness belongs to public CLI children.
# Sourced by editor-smoke.sh, sharing its fixture and editor helpers.
# shellcheck source=tests/lib/shell-connection.sh
source "$JAILBOX_DIR/tests/lib/shell-connection.sh"

occupy_editor_subnet() {
    local project=$1 ctr=$2 hash offset subnet name status
    local names="$LOG_DIR/$ctr.network-names" subnets="$LOG_DIR/$ctr.subnets" errors="$LOG_DIR/$ctr.network-inspect-error"
    hash=$(jailbox_project_hash_for_path "$project") || return 1
    offset=$(jailbox_project_hash_port_offset "$hash") || return 1
    subnet="10.240.$((1 + offset % 200)).0/24"
    ledger_record network "$ctr-editor-collision" || return 1
    if podman network create --internal --subnet "$subnet" "$ctr-editor-collision" >/dev/null 2>&1; then return 0; fi
    # An existing exact subnet also establishes the fixture; an unrelated
    # create failure does not. Cleanup only owns the ledger-recorded name.
    podman network ls --format '{{.Name}}' > "$names" || return 1
    while IFS= read -r name; do
        if ! podman network inspect "$name" --format '{{range .Subnets}}{{println .Subnet}}{{end}}' > "$subnets" 2> "$errors"; then
            # Listing and inspecting are separate operations. Only confirmed
            # disappearance is harmless; engine and existing-network errors fail.
            if podman network exists "$name"; then
                cat "$errors" >&2
                return 1
            else
                status=$?
                if [[ $status != 1 ]]; then cat "$errors" >&2; return 1; fi
            fi
            continue
        fi
        if grep -Fxq "$subnet" "$subnets"; then return 0; fi
    done < "$names"
    return 1
}

verify_editor_settings() (
    local project=$1 stage=$2 proxy profile name index hash offset
    for name in "${!JAILBOX_CONFIG_@}"; do unset "$name"; done
    export JAILBOX_CONFIG_DEV_IMAGE
    JAILBOX_CONFIG_DEV_IMAGE=$(stage_test_image "$stage") || return 1
    export JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
    if [[ $stage == egress ]]; then
        local hosts=(api.ipify.org)
        if [[ $(editor_name) == codium ]]; then
            hosts+=(github.com githubusercontent.com)
        else
            hosts+=(update.code.visualstudio.com vscode.download.prss.microsoft.com main.vscode-cdn.net vo.msecnd.net)
        fi
        for index in "${!hosts[@]}"; do export "JAILBOX_CONFIG_EGRESS_ALLOW_$index=${hosts[index]}"; done
    fi
    proxy=$(shell_connection_proxy "$project" "$JAILBOX_DIR/src/jailbox" "$LOG_DIR/$stage.editor-connection") || return 1
    profile=$(jailbox_editor_user_data "$project") || return 1
    python3 "$JAILBOX_DIR/tests/lib/editor/check-settings.py" "$profile/User/settings.json" "$(jailbox_ssh_config "$project")" "$proxy" || return 1
    python3 "$JAILBOX_DIR/tests/lib/editor/check-settings.py" "$project/.jailbox-editor-settings.json" "$(jailbox_ssh_config "$project")" "$proxy" || return 1
    if [[ $stage == egress ]]; then
        hash=$(jailbox_project_hash_for_path "$project") || return 1
        offset=$(jailbox_project_hash_port_offset "$hash") || return 1
        [[ $proxy != "http://10.240.$((1 + offset % 200)).2:8888" ]] || return 1
    fi
)

editor_public_launch() (
    local project=$1
    shift
    export JAILBOX_TEST_EDITOR_REAL JAILBOX_TEST_CLI="$JAILBOX_DIR/src/jailbox"
    JAILBOX_TEST_EDITOR_REAL=$(editor_bin) || return 1
    # Initial launch already seeded trust preferences; later policy variants
    # must not use that initial fixture's machine environment for seeding.
    export JAILBOX_TEST_SEED_SETTINGS=0
    cd "$project" || return 1
    PATH="$project/.vscode/test-editor-bin:$PATH" "$JAILBOX_DIR/src/jailbox" "$@"
)

editor_reopen() {
    local project=$1 stage=$2 ctr=$3 mode=$4 baseline run_id
    shift 4
    cleanup_editor_workspace "$project" "$ctr" || return 1
    baseline=$(snapshot_remote_editor_connections "$project" "$ctr") || return 1
    if [[ $mode == resume ]]; then podman stop "$ctr" >/dev/null || return 1; fi
    run_id="$(date +%s)-$RANDOM-$mode"
    printf '%s\n' "$run_id" > "$project/.jailbox-editor-run-id" || return 1
    rm -f "$project/$PROOF_FILE" "$project/$EXT_ACTIVATION_MARKER" "$project/$EXT_TASK_RESULT" "$project/.jailbox-editor-settings.json" || return 1
    editor_public_launch "$project" "$@" || return 1
    wait_for_remote_editor_ready "$project" "$ctr" "$EDITOR_TIMEOUT" "$baseline" || return 1
    wait_for_task_result "$project" || return 1
    validate_task_result "$project" "$run_id" || return 1
    validate_proof "$project" "$stage" "$run_id" || return 1
    pass "public frontend $mode opens a fresh working editor"
}

editor_policy_fixture() {
    printf 'DEV_IMAGE=%s\nEDITOR=%s\nEGRESS_ALLOW=%s\nREADONLY_PATHS=%s\n' "$2" "$3" "$4" "$5" > "$1"
}

verify_editor_workflows() {
    local project=$1 stage=$2 ctr=$3 selected other hosts image
    image=$(stage_test_image "$stage") || return 1
    editor_reopen "$project" "$stage" "$ctr" reopen || return 1
    editor_reopen "$project" "$stage" "$ctr" resume || return 1
    [[ $stage == egress ]] || return 0
    cleanup_editor_workspace "$project" "$ctr" || return 1
    selected=$(editor_name) || return 1
    other=code; [[ $selected != code ]] || other=codium
    # CI installs one pinned editor per job. The alternate client records
    # selection/launch while this job's real client proves actual attachment.
    cp "$JAILBOX_DIR/tests/fixtures/editor-client/editor.sh" "$project/.vscode/test-editor-bin/$other" || return 1
    chmod 755 "$project/.vscode/test-editor-bin/$other" || return 1
    local -x FAKE_TRACE="$project/switch-trace"
    : > "$FAKE_TRACE"
    if editor_public_launch "$project" --no-editor > "$project/refusal" 2>&1; then return 1; fi
    grep -q 'jailbox stop' "$project/refusal" || return 1
    editor_policy_fixture "$project/jailbox.conf" "$image" "$other" api.ipify.org '' || return 1
    if editor_public_launch "$project" > "$project/refusal" 2>&1; then return 1; fi
    grep -q 'jailbox stop' "$project/refusal" || return 1
    if grep -q '^launch:' "$FAKE_TRACE"; then return 1; fi
    editor_policy_fixture "$project/jailbox.conf" "$image" "$selected" api.ipify.org '' || return 1
    cp "$project/jailbox.conf" "$project/selected.conf" || return 1
    if editor_public_launch "$project" --config selected.conf > "$project/refusal" 2>&1; then return 1; fi
    grep -q 'jailbox stop' "$project/refusal" || return 1
    pass 'changed editor, headless, and config-anchor policies refuse'

    # Explicit recovery creates a policy where each switch is equivalent.
    (cd "$project" && "$JAILBOX_DIR/src/jailbox" stop) || return 1
    hosts=githubusercontent.com,api.ipify.org,github.com,vo.msecnd.net,main.vscode-cdn.net,vscode.download.prss.microsoft.com,update.code.visualstudio.com,api.ipify.org
    editor_policy_fixture "$project/jailbox.conf" "$image" "$selected" "$hosts" jailbox.conf,selected.conf || return 1
    cp "$project/jailbox.conf" "$project/selected.conf" || return 1
    editor_public_launch "$project" --no-editor || return 1
    editor_policy_fixture "$project/jailbox.conf" "$image" "$other" "$hosts" jailbox.conf,selected.conf || return 1
    : > "$FAKE_TRACE"
    editor_public_launch "$project" || return 1
    grep -qx "launch:$other" "$FAKE_TRACE" || return 1
    # selected.conf still selects the real pinned editor. It must attach and
    # run its task on the sandbox just used by the other/headless workflows.
    editor_reopen "$project" "$stage" "$ctr" switch --config selected.conf || return 1
    pass 'prelisted bootstrap hosts and anchors permit editor/headless/config switches'
}
