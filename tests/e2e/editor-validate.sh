#!/bin/bash
# Validation probe run inside the jailbox container by editor-smoke.sh after
# VS Code/VSCodium has established the Remote SSH session.
#
# Proof file format: one key=value per line, read by validate_proof().
set -eu

proof=.jailbox-editor-proof
run_id=$(cat .jailbox-editor-run-id)
test -n "$run_id"

write_probe=.jailbox-editor-write-check
: > "$write_probe"

{
    echo "run_id=$run_id"
    echo "whoami=$(whoami)"
    echo "uid=$(id -u)"
    echo "hostname=$(hostname)"
    echo "pwd=$(pwd)"
    echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "REMOTE_CONTAINERS=${REMOTE_CONTAINERS:-}"
    echo "VSCODE_IPC_HOOK_CLI=${VSCODE_IPC_HOOK_CLI:-}"
    if test -f /run/jailbox-sshd/authorized_keys; then
        echo "authorized_keys=present"
    else
        echo "authorized_keys=missing"
    fi
    if test -w .; then
        echo "workspace_writable=yes"
    else
        echo "workspace_writable=no"
    fi
    echo "sshd_dir=$(ls /run/jailbox-sshd/ 2>&1)"
    echo "HTTP_PROXY=${HTTP_PROXY:-}"
    echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
    echo "NO_PROXY=${NO_PROXY:-}"
    if [ -n "${HTTPS_PROXY:-}" ]; then
        echo "proxy_configured=yes"
    else
        echo "proxy_configured=no"
    fi
} > "$proof"

rm -f "$write_probe"
test "$(whoami)" = jailbox
test -f /run/jailbox-sshd/authorized_keys
test -w .
echo "jailbox editor validation probe passed"
