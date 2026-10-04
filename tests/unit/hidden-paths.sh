#!/bin/bash
# Native masks compose with the existing planner; no host placeholders exist.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
PROJECT_DIR=$(cd "$fixture" && pwd -P)/project
REMOTE_PATH=/home/jailbox/project
mkdir -p "$PROJECT_DIR/lane/hidden/child" "$PROJECT_DIR/readonly/child" "$PROJECT_DIR/-option"
printf original > "$PROJECT_DIR/lane/Containerfile"
printf hidden > "$PROJECT_DIR/dir,comma"
printf literal > "$PROJECT_DIR/-option/*[literal]"
printf 'FROM scratch\n' > "$PROJECT_DIR/lane/hidden/Containerfile"
chmod 755 "$PROJECT_DIR" "$PROJECT_DIR/lane" "$PROJECT_DIR/lane/hidden" "$PROJECT_DIR/lane/hidden/child" "$PROJECT_DIR/readonly" "$PROJECT_DIR/readonly/child" "$PROJECT_DIR/-option"
chmod 644 "$PROJECT_DIR/lane/Containerfile" "$PROJECT_DIR/dir,comma" "$PROJECT_DIR/-option/*[literal]" "$PROJECT_DIR/lane/hidden/Containerfile"
mkfifo "$PROJECT_DIR/fifo"
ln -s lane "$PROJECT_DIR/link"
ln -s "$PROJECT_DIR" "$fixture/project-alias"
apply_config_defaults
initialize_dev_image_state
rejects() {
    if ("$@") > "$fixture/output" 2>&1; then
        printf 'FAIL: accepted %s\n' "$*" >&2; exit 1
    fi
}
for path in '' /tmp . .. ./lane lane/../file lane/ lane//hidden lane:hidden missing fifo link link/hidden; do
    rejects check_hidden_path "$path"
done
for paths in 'lane lane' 'lane lane/hidden' 'lane/hidden lane'; do
    read -r -a HIDDEN_PATHS <<< "$paths"
    rejects finalize_effective_readonly_paths
done
# A host alias above the physical project is allowed.
[[ $(PROJECT_DIR="$fixture/project-alias" check_hidden_path lane/hidden) = lane/hidden ]]
HIDDEN_PATHS=('dir,comma' '-option/*[literal]' lane/Containerfile)
WRITABLE_PATHS=(lane)
READONLY_PATHS=(lane/Containerfile readonly)
SELECTED_DEV_CONTAINERFILE_INPUT="$PROJECT_DIR/lane/Containerfile"
build_readonly_mounts
[[ ${#HIDDEN_MASK_OPTIONS[@]} = 2 && ${HIDDEN_MASK_OPTIONS[0]} = --security-opt ]]
[[ ${HIDDEN_MASK_OPTIONS[1]} = "mask=$REMOTE_PATH/dir,comma:$REMOTE_PATH/-option/*[literal]:$REMOTE_PATH/lane/Containerfile" ]]
[[ ${#WRITABLE_MOUNTS[@]} = 2 && ${#READONLY_MOUNTS[@]} = 2 ]]
[[ ${READONLY_MOUNTS[1]} = "$PROJECT_DIR/readonly:$REMOTE_PATH/readonly:Z,ro,rprivate" ]]
# Hidden ancestors suppress both read-only and writable children, after full
# semantic validation. The base remains read-only even if every lane is masked.
HIDDEN_PATHS=(lane)
WRITABLE_PATHS=(lane)
READONLY_PATHS=(lane/Containerfile)
build_readonly_mounts
[[ -z ${READONLY_MOUNTS[*]-} && -z ${WRITABLE_MOUNTS[*]-} ]]
WRITABLE_PATHS=(lane/hidden/child)
READONLY_PATHS=(lane/Containerfile)
build_readonly_mounts
[[ -z ${READONLY_MOUNTS[*]-} && -z ${WRITABLE_MOUNTS[*]-} ]]
WRITABLE_PATHS=(lane/missing)
rejects build_readonly_mounts
WRITABLE_PATHS=(lane/Containerfile)
rejects build_readonly_mounts
WRITABLE_PATHS=()
READONLY_PATHS=(lane/missing)
rejects build_readonly_mounts
# Valid RO ancestor, hidden child, and selected Containerfile ancestor mask.
READONLY_PATHS=(lane)
HIDDEN_PATHS=(lane/hidden)
SELECTED_DEV_CONTAINERFILE_INPUT="$PROJECT_DIR/lane/hidden/Containerfile"
build_readonly_mounts
[[ ${#READONLY_MOUNTS[@]} = 2 && ${READONLY_MOUNTS[1]} = "$PROJECT_DIR/lane:$REMOTE_PATH/lane:Z,ro,rprivate" ]]
# A path replaced by a symlink is rejected when options are rebuilt.
rm "$PROJECT_DIR/dir,comma"
ln -s lane "$PROJECT_DIR/dir,comma"
HIDDEN_PATHS=('dir,comma')
rejects build_readonly_mounts
rm "$PROJECT_DIR/dir,comma"
printf hidden > "$PROJECT_DIR/dir,comma"
# Public validation consumes every indexed member without touching the engine.
(cd "$PROJECT_DIR" && env JAILBOX_CONFIG_DEV_IMAGE=fixture \
    JAILBOX_CONFIG_HIDDEN_PATHS_0='dir,comma' \
    JAILBOX_CONFIG_HIDDEN_PATHS_1='-option/*[literal]' "$ROOT/src/jailbox" validate)
printf 'DEV_IMAGE=fixture\nHIDDEN_PATHS=jailbox.conf\n' > "$PROJECT_DIR/jailbox.conf"
(cd "$PROJECT_DIR" && "$ROOT/src/jailbox" --config jailbox.conf validate)
printf 'DEV_IMAGE=fixture\nHIDDEN_PATHS=lane,lane/hidden\n' > "$PROJECT_DIR/jailbox.conf"
frontend_validate() { (cd "$PROJECT_DIR" && "$ROOT/src/jailbox" --config jailbox.conf validate); }
rejects frontend_validate
grep -q 'overlapping HIDDEN_PATHS' "$fixture/output"
# Mask destinations never authorize arbitrary .Mounts entries. Inspect masks
# separately, retain source/type/permissions on every surviving project mount.
HIDDEN_PATHS=(lane/hidden 'dir,comma')
READONLY_PATHS=(lane lane/hidden/Containerfile)
WRITABLE_PATHS=()
finalize_effective_readonly_paths
CONTAINER_NAME=fixture MANAGED_USER=jailbox VOLUME_NAME=fixture-home SSH_DIR=/state LOCAL_PORT=50222
validate_development_identity() { :; }
validate_ssh_container_mount() { :; }
require_container_properties() { printf '%s\n' "$@" >> "$fixture/predicates"; }
validate_development_mounts
grep -Fq '.Config.CreateCommand' "$fixture/predicates"
grep -Fq '(eq .Propagation "rprivate")' "$fixture/predicates"
grep -Fq "(eq .Source \"$PROJECT_DIR/lane\")" "$fixture/predicates"
if grep -Fq "(eq .Destination \"$REMOTE_PATH/lane/hidden" "$fixture/predicates"; then exit 1; fi
if grep -Fq "(eq .Destination \"$REMOTE_PATH/dir,comma\")" "$fixture/predicates"; then exit 1; fi
printf 'PASS: hidden paths, literal options, overlap precedence, rechecks, frontend and exact mount inventory\n'
