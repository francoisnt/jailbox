#!/bin/bash
# Shared deterministic engine/transport fixture; callers set ROOT.
# shellcheck disable=SC2034,SC2154 # Shared fixture exports state and consumes caller snapshots.
FIXTURE=$(mktemp -d)
# macOS temporary paths can traverse /var, a symlink rejected for SSH state.
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/project" "$FIXTURE/engine"
export GIT_CONFIG_GLOBAL="$FIXTURE/git-identity" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name 'Convergence Test'
git config --file "$GIT_CONFIG_GLOBAL" user.email 'convergence@example.invalid'
export CONVERGENCE_ENGINE="$FIXTURE/engine" CONVERGENCE_LOG="$FIXTURE/actions"
export XDG_STATE_HOME="$FIXTURE/state with spaces"
export CONVERGENCE_IMAGE=1111111111111111111111111111111111111111111111111111111111111111
export CONVERGENCE_PROXY_IMAGE=2222222222222222222222222222222222222222222222222222222222222222
export JAILBOX_CONFIG_DEV_IMAGE=localhost/convergence
export PATH="$FIXTURE/bin:$PATH"
cp "$ROOT/tests/fixtures/convergence/podman.sh" "$FIXTURE/bin/podman"
cp "$ROOT/tests/fixtures/convergence/ssh.sh" "$FIXTURE/bin/ssh"
# Avoid thirty seconds of readiness retries in deliberately failed starts.
cat > "$FIXTURE/bin/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP
chmod +x "$FIXTURE/bin/"*
# shellcheck source=src/host/core/project-id.sh
source "$ROOT/src/host/core/project-id.sh"
PREFIX=$(jailbox_resource_prefix_for_path "$FIXTURE/project")
HASH=$(jailbox_project_hash_for_path "$FIXTURE/project")
GENERATION="$XDG_STATE_HOME/jailbox/projects/$HASH/ssh-generation"

launch() { (cd "$FIXTURE/project" && "$ROOT/src/jailbox" "$@"); }
expect_success() {
    if ! launch up > "$FIXTURE/output" 2>&1; then cat "$FIXTURE/output"; exit 1; fi
}
expect_failure() {
    if launch up > "$FIXTURE/stdout" 2> "$FIXTURE/output"; then
        echo 'unexpected convergence success'
        cat "$FIXTURE/stdout" "$FIXTURE/output"
        exit 1
    fi
    if ! grep -q "$1" "$FIXTURE/output" || grep -q 'Sandbox is ready' "$FIXTURE/stdout"; then
        cat "$FIXTURE/stdout" "$FIXTURE/output"
        exit 1
    fi
}
snapshot() {
    find "$CONVERGENCE_ENGINE" "$XDG_STATE_HOME" -type f -exec cksum {} + | LC_ALL=C sort
}
assert_no_mutation() {
    [[ "$before" == "$(snapshot)" ]]
    if grep -Eq '^(run|start|stop|rm|sync|network create|volume create)' "$CONVERGENCE_LOG"; then
        echo 'refusal mutated state'; cat "$CONVERGENCE_LOG"; exit 1
    fi
}
