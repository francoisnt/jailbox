#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d /tmp/jailbox-e2e-git.XXXXXXXX)
trap 'rm -rf "$test_root"' EXIT
# shellcheck source=tests/lib/logging.sh
source "$ROOT/tests/lib/logging.sh"
# shellcheck source=tests/lib/resource-ledger.sh
source "$ROOT/tests/lib/resource-ledger.sh"
# shellcheck source=tests/lib/lifecycle-runtime.sh
source "$ROOT/tests/lib/lifecycle-runtime.sh"
# shellcheck source=host/container-runtime.sh
source "$ROOT/host/container-runtime.sh"
mkdir "$test_root/bin"
# Init checks for an existing container; no engine mutation is permitted.
cat > "$test_root/bin/podman" <<'ENGINE'
#!/bin/bash
[[ "$*" != container\ exists\ * ]] || exit 1
exit 97
ENGINE
chmod 755 "$test_root/bin/podman"
export PATH="$test_root/bin:$PATH"
for identity in absent configured; do
    (
        export HOME="$test_root/$identity-home"
        export XDG_CONFIG_HOME="$HOME/config" XDG_STATE_HOME="$HOME/state"
        export JAILBOX_TEST_LEDGER_DIR="$HOME/ledger"
        export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
        mkdir -p "$HOME"
        if [[ "$identity" = configured ]]; then
            printf '[user]\nname = Real User\nemail = real@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
            cp "$GIT_CONFIG_GLOBAL" "$HOME/before"
        fi
        export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Inherited
        export GIT_CONFIG_PARAMETERS="'user.email=inherited@example.invalid'"
        # Unscoped reads consume both override mechanisms; --global reads do not.
        [[ $(git -C "$HOME" config --get user.name) = Inherited ]]
        [[ $(git -C "$HOME" config --get user.email) = inherited@example.invalid ]]
        lifecycle_setup "$test_root/$identity-worker" "$test_root/$identity-log"
        [[ $(git -C "$PROJECT" config --get user.name) = 'Jailbox Test' ]]
        [[ $(git -C "$PROJECT" config --get user.email) = jailbox-test@example.invalid ]]
        output="$XDG_STATE_HOME/generated/gitconfig"
        generate_minimal_gitconfig "$output"
        [[ $(git config --file "$output" user.name) = 'Jailbox Test' ]]
        [[ $(git config --file "$output" user.email) = jailbox-test@example.invalid ]]
        if [[ "$identity" = configured ]]; then
            cmp "$HOME/before" "$HOME/.gitconfig"
        else
            [[ ! -e "$HOME/.gitconfig" ]]
        fi
    )
done
printf 'PASS: matrix setup publishes a dummy Git identity without depending on or changing host configuration\n'
