#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
PROJECT_DIR=$(cd "$fixture" && pwd -P)
REMOTE_PATH=/home/jailbox/project
apply_config_defaults
initialize_dev_image_state
mkdir -p "$PROJECT_DIR/src/policy" "$PROJECT_DIR/build" "$PROJECT_DIR/dir,comma"
printf original > "$PROJECT_DIR/file"
printf 'FROM scratch\n' > "$PROJECT_DIR/src/Containerfile"
mkfifo "$PROJECT_DIR/fifo"
ln -s src "$PROJECT_DIR/link"
rejects() {
    if ("$@") > "$fixture/output" 2>&1; then
        printf 'FAIL: accepted %s\n' "$*" >&2; exit 1
    fi
}
for path in '' /tmp . .. ./src src/../file src/ src//policy src:policy missing fifo link link/policy; do
    rejects check_writable_path "$path"
done
for paths in 'src src' 'src src/policy' 'src/policy src'; do
    read -r -a WRITABLE_PATHS <<< "$paths"
    rejects validate_writable_paths_lexical
done
WRITABLE_PATHS=(src build 'dir,comma' file)
READONLY_PATHS=(src/policy)
SELECTED_DEV_CONTAINERFILE_INPUT="$PROJECT_DIR/src/Containerfile"
build_readonly_mounts
[[ ${#WRITABLE_MOUNTS[@]} = 8 && ${#READONLY_MOUNTS[@]} = 4 ]]
[[ ${WRITABLE_MOUNTS[*]} = *"$PROJECT_DIR/dir,comma:$REMOTE_PATH/dir,comma:Z,rw"* ]]
for path in src/policy src/policy/child src/Containerfile; do
    [[ "$path" != */child ]] || mkdir "$PROJECT_DIR/$path"
    WRITABLE_PATHS=("$path")
    rejects finalize_effective_readonly_paths
done
WRITABLE_PATHS=(file)
build_readonly_mounts
rm "$PROJECT_DIR/file"
ln -s src "$PROJECT_DIR/file"
rejects build_readonly_mounts
rm "$PROJECT_DIR/file"
printf original > "$PROJECT_DIR/file"
# A protected symlink target cannot be exposed through a writable lane either.
ln -s ../../build "$PROJECT_DIR/src/policy/build"
WRITABLE_PATHS=(build)
rejects finalize_effective_readonly_paths
rm "$PROJECT_DIR/src/policy/build"
# Lexical and physical validation stay engine independent through public validate.
(cd "$PROJECT_DIR" && env JAILBOX_CONFIG_DEV_IMAGE=fixture \
    JAILBOX_CONFIG_WRITABLE_PATHS_0='dir,comma' "$ROOT/src/jailbox" validate)
# The frontend must retain duplicate writable entries for core refusal, and
# its policy anchor cannot be made writable by file configuration.
frontend_validate() { (cd "$PROJECT_DIR" && "$ROOT/src/jailbox" --config jailbox.conf validate); }
printf 'DEV_IMAGE=fixture\nWRITABLE_PATHS=file,file\n' > "$PROJECT_DIR/jailbox.conf"
rejects frontend_validate
grep -q 'overlapping WRITABLE_PATHS' "$fixture/output"
printf 'DEV_IMAGE=fixture\nWRITABLE_PATHS=jailbox.conf\n' > "$PROJECT_DIR/jailbox.conf"
rejects frontend_validate
grep -q 'is protected' "$fixture/output"
# Read exact predicates: every lane needs its own source/type/RW check and only
# exact destinations enter the inventory; descendants never get blanket access.
WRITABLE_PATHS=(src file)
finalize_effective_readonly_paths
CONTAINER_NAME=fixture
MANAGED_USER=jailbox
VOLUME_NAME="fixture-home"
SSH_DIR=/state
LOCAL_PORT=50222
validate_development_identity() { :; }
validate_ssh_container_mount() { :; }
require_container_properties() { printf '%s\n' "$@" >> "$fixture/predicates"; }
validate_development_mounts
grep -Fq '(eq .RW false)' "$fixture/predicates"
grep -Fq "(eq .Source \"$PROJECT_DIR/src\")" "$fixture/predicates"
grep -Fq "(eq .Destination \"$REMOTE_PATH/file\")" "$fixture/predicates"
# Empty policy retains the original writable project mount predicate.
WRITABLE_PATHS=()
: > "$fixture/predicates"
validate_development_mounts
head -2 "$fixture/predicates" | grep -Fq '(eq .RW true)'
printf 'PASS: writable path validation, protected precedence, rechecks and exact mount inventory\n'
