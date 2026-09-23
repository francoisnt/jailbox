#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf -- "$fixture"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$fixture/home/project" "$fixture/state" "$fixture/project" "$fixture/bin"
export HOME="$fixture/home" XDG_STATE_HOME="$fixture/state"
export JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev
PROJECT_DIR=$HOME/project
validate_project_boundary || fail 'ordinary project beneath home refused'
PROJECT_DIR=$fixture/project
validate_project_boundary || fail 'project outside home refused'
for PROJECT_DIR in / "$fixture" "$HOME"; do
    if (validate_project_boundary) > "$fixture/out" 2> "$fixture/err"; then fail 'project contains HOME'; fi
    grep -q 'contains host HOME' "$fixture/err"
done
PROJECT_DIR=$fixture/project
for XDG_STATE_HOME in "$PROJECT_DIR/state" "$PROJECT_DIR/missing/state" "$PROJECT_DIR/../project/state"; do
    if (validate_project_boundary) > "$fixture/out" 2> "$fixture/err"; then fail 'project contains state'; fi
    grep -q 'contains jailbox runtime state' "$fixture/err"
done
ln -s "$PROJECT_DIR" "$fixture/state-alias"
XDG_STATE_HOME=$fixture/state-alias
if (validate_project_boundary); then fail 'symlinked state overlap accepted'; fi
XDG_STATE_HOME=$fixture/state
ln -s "$PROJECT_DIR" "$fixture/home-alias"
if (HOME=$fixture/home-alias; validate_project_boundary); then fail 'symlinked HOME overlap accepted'; fi
(
    realpath() { printf '/plausible\n'; return 42; }
    if validate_project_boundary; then fail 'failed canonicalization accepted'; fi
)
# Real CLI refuses before Podman inspection/mutation or credential generation.
# shellcheck disable=SC2016 # Expanded by the executable fixture, not this writer.
printf '#!/bin/bash\nprintf called >> "$BOUNDARY_ENGINE_LOG"\nexit 125\n' > "$fixture/bin/podman"
chmod 755 "$fixture/bin/podman"
export BOUNDARY_ENGINE_LOG=$fixture/engine
for command in validate up connection-info; do
    if (cd "$PROJECT_DIR"; XDG_STATE_HOME="$PROJECT_DIR/state" PATH="$fixture/bin:$PATH" "$ROOT/src/jailbox" "$command") > "$fixture/out" 2> "$fixture/err"; then
        fail "$command allowed project-contained state"
    fi
    grep -q 'contains jailbox runtime state' "$fixture/err"
    [[ ! -e "$fixture/engine" && ! -e "$PROJECT_DIR/state" ]] || fail 'boundary refusal touched engine or state'
done
printf 'PASS: home/state containment, physical paths, failed producers, and pre-mutation CLI refusal\n'
