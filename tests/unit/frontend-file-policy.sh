#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/host/frontend/file-policy.sh
source "$ROOT/src/host/frontend/file-policy.sh"
# shellcheck source=src/host/frontend/init.sh
source "$ROOT/src/host/frontend/init.sh"
TMP=$(mktemp -d)
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf -- "$TMP"' EXIT
mkdir "$TMP/project"
project=$TMP/project
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() {
    local message=$1
    shift
    if ("$@") > "$TMP/out" 2> "$TMP/err"; then fail "accepted $message"; fi
    grep -Fq -- "$message" "$TMP/err" || { cat "$TMP/err"; fail "missing diagnostic: $message"; }
}
load() { load_file_policy "$project" "${1:-}"; }
policy_has() {
    local entry
    for entry in "${FRONTEND_ENVIRONMENT[@]}"; do
        [[ "$entry" != "$1" ]] || return 0
    done
    fail "missing policy entry $1"
}
policy_lacks_prefix() {
    local entry
    for entry in "${FRONTEND_ENVIRONMENT[@]}"; do
        [[ "$entry" != "$1"* ]] || fail "unexpected policy entry $entry"
    done
}

# Grammar, repeated parsing, and file/line diagnostics.
printf '%s\n' '# full-line comment' ' DEV_IMAGE="alpine:3" ' "EGRESS_ALLOW='example.com,example.org'" 'EDITOR=code' > "$project/jailbox.conf"
load
[[ ${FRONTEND_VALUES[DEV_IMAGE]} == alpine:3 && ${FRONTEND_VALUES[EGRESS_ALLOW]} == example.com,example.org && ${FRONTEND_VALUES[EDITOR]} == code ]]
# shellcheck disable=SC2016 # Literal shell syntax must be rejected, never expanded.
for body in 'UNKNOWN=x' 'DEV_IMAGE=x,y' 'DEV_IMAGE=x y' 'DEV_IMAGE=$(id)' 'DEV_IMAGE=x # comment' 'DEV_IMAGE="x' 'DEV_IMAGE =x' 'EGRESS_ALLOW=x,,y' 'EGRESS_ALLOW=x,' 'EGRESS_ALLOW=,x' $'DEV_IMAGE=x\nDEV_IMAGE=y'; do
    printf '# header\n%s\n' "$body" > "$project/jailbox.conf"
    reject "invalid config '$project/jailbox.conf' line" load
done
# All non-NUL controls in an atom, including DEL. LF splits the assignment and
# is rejected as a malformed next line rather than accepted as part of a value.
for ((byte=1; byte<=127; byte++)); do
    ((byte < 32 || byte == 127)) || continue
    printf -v octal '%03o' "$byte"
    printf 'DEV_IMAGE=a%bZ\n' "\\$octal" > "$project/jailbox.conf"
    reject "invalid config '$project/jailbox.conf' line" load
done
for body in $'DEV_IMAGE=x\n# comment' 'DEV_IMAGE=alpine' '# comment' ''; do
    printf '%s\0ignored\n' "$body" > "$project/jailbox.conf"
    reject 'NUL byte in file' load
done
printf '# comment\nDEV_IMAGE=a\0b\n' > "$project/jailbox.conf"
reject "line 2: NUL byte" load
printf '\t# comment\r\n DEV_IMAGE=alpine \r\nREADONLY_PATHS=\n' > "$project/jailbox.conf"
load
[[ ${FRONTEND_VALUES[DEV_IMAGE]} == alpine ]]
printf 'EDITOR=invalid\n' > "$project/jailbox.conf"
reject 'invalid EDITOR' load

# Default required even with an external selection; trust checks cover parent
# symlinks, dot traversal, special files, control bytes and non-readable files.
printf 'DEV_IMAGE=alpine\n' > "$TMP/external.conf"
rm "$project/jailbox.conf"
reject 'jailbox.conf is required' load "$TMP/external.conf"
ln -s "$TMP/external.conf" "$project/jailbox.conf"
reject 'symlink' load "$TMP/external.conf"
rm "$project/jailbox.conf"
printf 'READONLY_PATHS=jailbox.conf,selected.conf,jailbox.conf\nEGRESS_ALLOW=example.com,example.com\n' > "$project/jailbox.conf"
cp "$project/jailbox.conf" "$project/selected.conf"
ln -s "$project" "$TMP/link"
reject 'symlink' load "$TMP/link/../external.conf"
reject 'regular file' load "$project"
mkfifo "$TMP/fifo"
reject 'regular file' load "$TMP/fifo"
reject 'ASCII control' load "$TMP/"$'bad\tpath'
chmod 000 "$TMP/external.conf"
if [[ ! -r "$TMP/external.conf" ]]; then reject 'readable regular file' load "$TMP/external.conf"; fi
chmod 600 "$TMP/external.conf"

# Inherited namespace replacement and unrelated byte preservation, including
# values containing line delimiters. Notices must not disclose ignored values.
export JAILBOX_CONFIG_DEV_IMAGE=private-secret JAILBOX_CONFIG_UNKNOWN=other-secret
export JAILBOX_CONFIG_READONLY_PATHS_90=third-secret
export JAILBOX_EDITOR=invalid EDITOR=invalid FRONTEND_TEST_UNRELATED=$'one\ntwo\tthree'
export XDG_CONFIG_HOME=$TMP/xdg CONTAINER_HOST=unix:///fixture/podman.sock DBUS_SESSION_BUS_ADDRESS=unix:path=/fixture/dbus
load "$project/selected.conf"
compose_machine_environment example.org example.com 2> "$TMP/notice"
policy_has JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
policy_has JAILBOX_CONFIG_READONLY_PATHS_1=selected.conf
policy_has JAILBOX_CONFIG_EGRESS_ALLOW_0=example.com
policy_has JAILBOX_CONFIG_EGRESS_ALLOW_1=example.org
policy_has "FRONTEND_TEST_UNRELATED=$FRONTEND_TEST_UNRELATED"
policy_has JAILBOX_EDITOR=invalid
policy_has EDITOR=invalid
for name in PATH HOME XDG_CONFIG_HOME CONTAINER_HOST DBUS_SESSION_BUS_ADDRESS; do
    policy_has "$name=${!name}"
done
policy_lacks_prefix JAILBOX_CONFIG_DEV_IMAGE=
policy_lacks_prefix JAILBOX_CONFIG_EDITOR=
policy_lacks_prefix JAILBOX_CONFIG_UNKNOWN=
policy_lacks_prefix JAILBOX_CONFIG_READONLY_PATHS_2=
grep -q JAILBOX_CONFIG_UNKNOWN "$TMP/notice"
grep -q 'jailbox up' "$TMP/notice"
if grep -q secret "$TMP/notice"; then fail 'notice leaks values'; fi
load "$TMP/external.conf"
compose_machine_environment example.org 2> "$TMP/notice"
policy_has JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf
policy_lacks_prefix JAILBOX_CONFIG_READONLY_PATHS_1=
policy_lacks_prefix JAILBOX_CONFIG_EGRESS_ALLOW
# A relative --config remains relative to the invocation directory.
(cd "$TMP"; load external.conf; [[ $FRONTEND_CONFIG == "$TMP/external.conf" ]])
printf 'EGRESS_ALLOW=\nREADONLY_PATHS=\n' > "$project/jailbox.conf"
load
compose_machine_environment example.org 2> "$TMP/notice"
policy_has JAILBOX_CONFIG_EGRESS_ALLOW=
policy_lacks_prefix JAILBOX_CONFIG_EGRESS_ALLOW_0=

# Declaration-driven generic mapping, plus explicit coverage for file-only keys.
(
    CONFIG_SCALAR_KEYS+=(FUTURE_SCALAR)
    CONFIG_ARRAY_KEYS+=(FUTURE_ARRAY)
    CONFIG_DEFAULTS+=(FUTURE_SCALAR= FUTURE_ARRAY=)
    initialize_public_api_lookups
    printf 'FUTURE_SCALAR=value\nFUTURE_ARRAY=one,two,one\n' > "$project/jailbox.conf"
    load
    compose_machine_environment 2> "$TMP/notice"
    policy_has JAILBOX_CONFIG_FUTURE_SCALAR=value
    policy_has JAILBOX_CONFIG_FUTURE_ARRAY_0=one
    policy_has JAILBOX_CONFIG_FUTURE_ARRAY_1=two
    policy_lacks_prefix JAILBOX_CONFIG_FUTURE_ARRAY_2=
)
missing_validator() {
    FRONTEND_SCALAR_KEYS+=(FUTURE_FRONTEND)
    FRONTEND_DEFAULTS+=(FUTURE_FRONTEND=)
    initialize_public_api_lookups
    load
}
printf 'DEV_IMAGE=alpine\n' > "$project/jailbox.conf"
reject "missing mapping 'FUTURE_FRONTEND'" missing_validator
# Required producer failure must not publish a ready environment.
failed_environment() {
    env() { printf 'UNRELATED=partial\0'; return 42; }
    compose_machine_environment
}
reject 'could not read inherited environment' failed_environment

# The validation path invokes exactly one public child and passes its failure
# through, without success text or any editor/lifecycle call.
cp "$ROOT/tests/fixtures/frontend-core.sh" "$TMP/core"
chmod 700 "$TMP/core"
export FRONTEND_TEST_CALLS=$TMP/calls FRONTEND_TEST_ENV=$TMP/environment
validate_file_config "$TMP/core" "$project" "$project/jailbox.conf" > "$TMP/out" 2> "$TMP/notice"
[[ $(cat "$TMP/calls") == validate && ! -s "$TMP/out" ]]
while IFS= read -r -d '' entry; do
    case "$entry" in
        JAILBOX_CONFIG_DEV_IMAGE=alpine|JAILBOX_CONFIG_READONLY_PATHS_0=jailbox.conf) ;;
        JAILBOX_CONFIG_*) fail "unexpected child policy: $entry" ;;
    esac
done < "$TMP/environment"
# Reusing the composed snapshot cannot pick up later caller environment edits.
cp "$TMP/environment" "$TMP/first-environment"
export FRONTEND_TEST_UNRELATED=changed-after-composition
run_core_command "$TMP/core" validate
cmp "$TMP/first-environment" "$TMP/environment"
export FRONTEND_TEST_STATUS=43
status=0
validate_file_config "$TMP/core" "$project" "$project/jailbox.conf" > "$TMP/out" 2> "$TMP/notice" || status=$?
[[ $status == 43 && ! -s "$TMP/out" ]]
printf 'DEV_IMAGE=bad value\n' > "$project/jailbox.conf"
reject 'invalid config' validate_file_config "$TMP/core" "$project" "$project/jailbox.conf"
[[ $(wc -l < "$TMP/calls") == 3 ]]
printf 'PASS: prepared frontend file grammar, trust, policy, and validation\n'
