#!/bin/bash
# Independent overlap expectations and failure publication for effective policy.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/lib/core.sh
source "$ROOT/tests/lib/core.sh" "$ROOT/src"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
PROJECT_DIR=$(cd "$fixture" && pwd -P)
REMOTE_PATH=/project
mkdir -p "$PROJECT_DIR/a/b/c/d/e" "$PROJECT_DIR/a/b/sibling" "$PROJECT_DIR/ab"
printf 'FROM scratch\n' > "$PROJECT_DIR/a/b/Containerfile"
chmod 755 "$PROJECT_DIR" "$PROJECT_DIR/a" "$PROJECT_DIR/a/b" "$PROJECT_DIR/a/b/c" \
    "$PROJECT_DIR/a/b/c/d" "$PROJECT_DIR/a/b/c/d/e" "$PROJECT_DIR/a/b/sibling" "$PROJECT_DIR/ab"
chmod 644 "$PROJECT_DIR/a/b/Containerfile"
apply_config_defaults
initialize_dev_image_state
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Both consumers must reject missing/failed preparation before any engine or
# SSH work, while a successfully finalized empty policy remains valid.
(
    CONTAINER_NAME=fixture MANAGED_USER=jailbox VOLUME_NAME=fixture-home SSH_DIR=/state LOCAL_PORT=50222
    validation_ssh() { cat >/dev/null; printf 'ssh\n' >> "$fixture/calls"; printf 'ok\n'; }
    validate_development_identity() { printf 'identity\n' >> "$fixture/calls"; }
    validate_ssh_container_mount() { :; }
    require_container_properties() { printf 'inspect\n' >> "$fixture/calls"; }
    reject_unready_consumers() {
        local consumer
        : > "$fixture/calls"
        for consumer in validate_development_mounts check_readonly_mounts validate_running_development; do
            if "$consumer" > "$fixture/output" 2> "$fixture/diagnostic"; then fail "$consumer accepted unfinalized policy"; fi
            grep -q 'project path policy has not been finalized' "$fixture/diagnostic"
            [[ ! -s "$fixture/output" && ! -s "$fixture/calls" ]] || fail 'unready policy reached external checks'
        done
    }
    reject_unready_consumers
    finalize_project_path_policy
    validate_development_mounts
    check_readonly_mounts
    grep -qx inspect "$fixture/calls"
    grep -qx ssh "$fixture/calls"
    initialize_container_runtime_state
    reject_unready_consumers
    finalize_project_path_policy
    WRITABLE_PATHS=(a)
    # shellcheck disable=SC2329 # Fail after a prior successful finalization.
    check_writable_path() { printf 'a\n'; return 42; }
    if finalize_project_path_policy; then fail 'failed preparation accepted'; fi
    reject_unready_consumers
)

# Rows specify RO, RW, hidden inputs followed by their expected surviving sets.
# A dash means empty. Expectations are not computed by production helpers.
while read -r ro rw hidden expected_ro expected_rw expected_hidden; do
    READONLY_PATHS=(); WRITABLE_PATHS=(); HIDDEN_PATHS=()
    [[ "$ro" = - ]] || IFS=, read -r -a READONLY_PATHS <<< "$ro"
    [[ "$rw" = - ]] || IFS=, read -r -a WRITABLE_PATHS <<< "$rw"
    [[ "$hidden" = - ]] || IFS=, read -r -a HIDDEN_PATHS <<< "$hidden"
    build_project_mounts 2> "$fixture/diagnostic"
    [[ ! -s "$fixture/diagnostic" ]] || fail "overlap warned: $ro $rw $hidden"
    [[ ${EFFECTIVE_READONLY_PATHS[*]:--} = "$expected_ro" &&
       ${EFFECTIVE_WRITABLE_PATHS[*]:--} = "$expected_rw" &&
       ${EFFECTIVE_HIDDEN_PATHS[*]:--} = "$expected_hidden" ]] || fail "overlap result: $ro $rw $hidden"
done <<'CASES'
a a - a - -
a a/b - a a/b -
a/b a - a/b a -
a - a - - a
a - a/b a - a/b
a/b - a - - a
- a a - - a
- a a/b - a a/b
- a/b a - - a
a a a - - a
a a/b a/b/c a a/b a/b/c
a a/b/c a/b a - a/b
a/b a a/b/c a/b a a/b/c
a/b/c a a/b - a a/b
a/b a/b/c a - - a
a/b/c a/b a - - a
a a a/b a - a/b
a/b a a - - a
a - ab a - ab
CASES

# Exact duplicates leave configuration/digest identity intact while producing
# one mount or mask. Check each public path category separately.
DEV_IMAGE=fixture
for key in READONLY_PATHS WRITABLE_PATHS HIDDEN_PATHS; do
    READONLY_PATHS=(); WRITABLE_PATHS=(); HIDDEN_PATHS=()
    set_config_array "$key" a
    before=$(config_digest_value launch)
    set_config_array "$key" a a
    validate_machine_config
    repeated=$(config_digest_value launch)
    [[ "$repeated" != "$before" ]] || fail "$key repetitions absent from digest"
    build_project_mounts
    [[ $(config_digest_value launch) = "$repeated" ]] || fail "$key mutated configuration"
    if [[ "$key" = HIDDEN_PATHS ]]; then
        [[ -z ${PROJECT_MOUNTS[*]-} && ${HIDDEN_MASK_OPTIONS[1]} = mask=/project/a ]] || fail 'duplicate mask'
    else
        [[ ${#PROJECT_MOUNTS[@]} = 2 ]] || fail 'duplicate overlay'
    fi
done

# Several alternating exceptions in reverse input order; a same-category
# ancestor cannot make the inner restriction redundant. Automatic files win.
HIDDEN_PATHS=()
READONLY_PATHS=(a/b/c a)
WRITABLE_PATHS=(a/b/c/d a/b a/b/Containerfile)
SELECTED_DEV_CONTAINERFILE_INPUT=$PROJECT_DIR/a/b/Containerfile
build_project_mounts
expected=(-v "$PROJECT_DIR/a:/project/a:Z,ro,rprivate"
    -v "$PROJECT_DIR/a/b:/project/a/b:Z,rw,rprivate"
    -v "$PROJECT_DIR/a/b/Containerfile:/project/a/b/Containerfile:Z,ro,rprivate"
    -v "$PROJECT_DIR/a/b/c:/project/a/b/c:Z,ro,rprivate"
    -v "$PROJECT_DIR/a/b/c/d:/project/a/b/c/d:Z,rw,rprivate")
[[ ${PROJECT_MOUNTS[*]} = "${expected[*]}" ]] || fail 'alternating mount order'
READONLY_PATHS=(a a/b/c)
WRITABLE_PATHS=(a/b/Containerfile a/b a/b/c/d)
build_project_mounts
[[ ${PROJECT_MOUNTS[*]} = "${expected[*]}" ]] || fail 'array order changed mounts'
READONLY_PATHS=()
WRITABLE_PATHS=(a/b/Containerfile)
build_project_mounts
[[ -z ${EFFECTIVE_WRITABLE_PATHS[*]-} && -n ${WRITABLE_PATHS[*]-} &&
   ${EFFECTIVE_READONLY_PATHS[*]} = a/b/Containerfile ]] || fail 'automatic file tie'
HIDDEN_PATHS=(a/b)
build_project_mounts
[[ -z ${PROJECT_MOUNTS[*]-} && -n ${WRITABLE_PATHS[*]-} ]] || fail 'hidden automatic input'

# Suppressed entries still require valid filesystem paths. Each producer is
# checked even with plausible output and under conditional invocation.
for key in READONLY_PATHS WRITABLE_PATHS HIDDEN_PATHS; do
    (
        READONLY_PATHS=(); WRITABLE_PATHS=(); HIDDEN_PATHS=(a)
        set_config_array "$key" a/missing
        if build_project_mounts; then exit 0; else exit 1; fi
    ) > "$fixture/diagnostic" 2>&1 && fail "suppressed invalid $key accepted"
done
(
    READONLY_PATHS=(a); WRITABLE_PATHS=(); HIDDEN_PATHS=()
    SELECTED_DEV_CONTAINERFILE_INPUT=''
    # shellcheck disable=SC2329 # Inject a failed required producer.
    check_readonly_path() { printf 'a\n'; return 42; }
    if build_project_mounts; then fail 'failed validator accepted'; fi
    [[ -z ${PROJECT_MOUNTS[*]-} && -z ${EFFECTIVE_READONLY_PATHS[*]-} &&
       -z ${EFFECTIVE_WRITABLE_PATHS[*]-} && -z ${EFFECTIVE_HIDDEN_PATHS[*]-} ]]
)
(
    # shellcheck disable=SC2329 # Sorting failure must not publish mask state.
    sort() { printf 'a\n'; return 42; }
    if build_project_mounts; then fail 'failed sorting accepted'; fi
    [[ "$PROJECT_PATH_POLICY_READY" = false ]] || fail 'failed sorting retained ready policy'
    [[ -z ${PROJECT_MOUNTS[*]-} && -z ${HIDDEN_MASK_OPTIONS[*]-} &&
       -z ${EFFECTIVE_HIDDEN_PATHS[*]-} ]]
)
# The live mount checker validates exact mount flags across nested exceptions.
# A child mount below a mask remains forbidden even when its own flags are RO.
cat > "$fixture/mountinfo" <<'MOUNTS'
10 1 0:1 / /project ro - ext4 /dev/root rw
11 10 0:1 /a /project/a ro - ext4 /dev/root rw
12 11 0:1 /a/b /project/a/b rw - ext4 /dev/root rw
13 12 0:1 /a/b/c /project/a/b/c ro - ext4 /dev/root rw
14 13 0:1 /a/b/c/d /project/a/b/c/d rw - ext4 /dev/root rw
15 14 0:2 / /project/a/b/c/d/hidden ro - tmpfs tmpfs ro
MOUNTS
checker=$ROOT/src/container/runtime/lib/jailbox/readonly-mount.awk
for path in /project /project/a /project/a/b/c; do
    TARGET=$path EXPECTED=ro awk -f "$checker" "$fixture/mountinfo"
done
for path in /project/a/b /project/a/b/c/d; do
    TARGET=$path EXPECTED=rw awk -f "$checker" "$fixture/mountinfo"
    if TARGET=$path EXPECTED=ro awk -f "$checker" "$fixture/mountinfo"; then fail 'writable mount accepted as readonly'; fi
done
TARGET=/project/a/b/c/d/hidden EXPECTED=mask-directory awk -f "$checker" "$fixture/mountinfo"
printf '16 15 0:1 /secret /project/a/b/c/d/hidden/child ro - ext4 /dev/root rw\n' >> "$fixture/mountinfo"
if TARGET=/project/a/b/c/d/hidden EXPECTED=mask-directory awk -f "$checker" "$fixture/mountinfo"; then
    fail 'mask checker accepted descendant overlay'
fi
printf 'PASS: path precedence, duplicate identity, alternating overlays and failed policy publication\n'
