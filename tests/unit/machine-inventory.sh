#!/bin/bash
# Byte formats, dependency isolation, and fail-closed inventory discovery.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASH_BIN=$(command -v bash)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$tmp/project" "$tmp/home" "$tmp/bin" "$tmp/source"
cp "$ROOT/src/jailbox" "$tmp/source/jailbox"
cp -R "$ROOT/src/host" "$tmp/source/host"
cp "$ROOT/src/public-api.sh" "$tmp/source/public-api.sh"
for tool in bash dirname basename tr cut sed cat; do
    ln -s "$(command -v "$tool")" "$tmp/bin/$tool"
done
# No configuration, SSH, editor, digest, or runtime state may be consumed.
printf 'invalid configuration\n' > "$tmp/project/jailbox.conf"
export HOME="$tmp/home" XDG_STATE_HOME="$tmp/state"
export JAILBOX_CONFIG_UNDECLARED=invalid JAILBOX_CONFIG_CPU_LIMIT=invalid
cd "$tmp/project"
cli() { PATH="$tmp/bin" "$BASH_BIN" "$tmp/source/jailbox" "$@"; }
success() {
    local expected="$1"
    shift
    "$@" > "$tmp/out" 2> "$tmp/err" || fail "command failed: $*"
    printf '%s\n' "$expected" > "$tmp/expected"
    cmp -s "$tmp/expected" "$tmp/out" || fail "wrong bytes: $*"
    [[ ! -s "$tmp/err" ]] || fail "unexpected diagnostics: $*"
}
failure() {
    if "$@" > "$tmp/out" 2> "$tmp/err"; then fail "accepted failure: $*"; fi
    [[ ! -s "$tmp/out" && -s "$tmp/err" ]] || fail "wrong failure streams: $*"
}

schema=$'DEV_IMAGE\tscalar\nDEV_CONTAINERFILE\tscalar\nDEV_BUILD_CONTEXT\tscalar\nDEV_TARGET_STAGE\tscalar\nMEMORY_LIMIT\tscalar\nCPU_LIMIT\tscalar\nPIDS_LIMIT\tscalar\nEPHEMERAL_HOME\tscalar\nEGRESS_ALLOW\tarray\nREADONLY_PATHS\tarray'
success "$schema" cli config-schema
failure cli status # Podman is required, even for absence.
for command in config-schema status; do
    failure cli "$command" extra
    failure cli "$command" --config /missing
    cli --help > "$tmp/help"
    grep -Eq "(\\[|\\|)$command(\\||\\])" "$tmp/help" || fail "missing synopsis: $command"
    grep -Eq "^  $command +" "$tmp/help" || fail "missing help: $command"
done

# Newly declared members flow through the real dispatcher, with every required
# per-key mapping supplied. No renderer list is updated.
cat >> "$tmp/source/public-api.sh" <<'API'
CONFIG_SCALAR_KEYS+=(SAMPLE_SCALAR)
CONFIG_ARRAY_KEYS+=(SAMPLE_ARRAY)
CONFIG_DEFAULTS+=('SAMPLE_SCALAR=' 'SAMPLE_ARRAY=')
API
printf '\nDIGEST_ARRAY_MODES[SAMPLE_ARRAY]=ordered\n' >> "$tmp/source/host/core/configuration/digest.sh"
extended=${schema/$'EGRESS_ALLOW\tarray'/$'SAMPLE_SCALAR\tscalar\nEGRESS_ALLOW\tarray'}
success "$extended"$'\nSAMPLE_ARRAY\tarray' cli config-schema
cp "$ROOT/src/host/core/configuration/digest.sh" "$tmp/source/host/core/configuration/digest.sh"
for declaration in \
    'CONFIG_ARRAY_KEYS+=(DEV_IMAGE)' \
    'CONFIG_SCALAR_KEYS+=(DEV_IMAGE)' \
    'CONFIG_SCALAR_KEYS+=(invalid)' \
    'CONFIG_ARRAY_KEYS+=(MISSING_DEFAULT)' \
    'CONFIG_ARRAY_KEYS+=(READONLY_PATHS_0)'; do
    cp "$ROOT/src/public-api.sh" "$tmp/source/public-api.sh"
    printf '\n%s\n' "$declaration" >> "$tmp/source/public-api.sh"
    failure cli config-schema
done
cp "$ROOT/src/public-api.sh" "$tmp/source/public-api.sh"

# Derive expected names using the existing identity contract, then assert that
# the stub sees precisely these resources, never images, labels, or SSH state.
# shellcheck source=src/host/core/project/hash.sh
source "$ROOT/src/host/core/project/hash.sh"
export TEST_PREFIX
TEST_PREFIX=$(jailbox_resource_prefix_for_path "$(pwd -P)")
export TEST_CALLS="$tmp/calls" TEST_PRESENT='' TEST_RUNNING=false TEST_FAULT='' TEST_PARTIAL=''
cp "$ROOT/tests/fixtures/inventory-podman.sh" "$tmp/bin/podman"
chmod 755 "$tmp/bin/podman"
failure cli status # Missing hash utility must not reach Podman.
[[ ! -e "$TEST_CALLS" ]] || fail 'engine called after identity failure'
if command -v sha256sum >/dev/null; then hash_tool=sha256sum; else hash_tool=shasum; fi
ln -s "$(command -v "$hash_tool")" "$tmp/bin/$hash_tool"

resources=("$TEST_PREFIX" "$TEST_PREFIX-proxy" "$TEST_PREFIX-net" \
    "$TEST_PREFIX-net-internal" "$TEST_PREFIX-net-external" "$TEST_PREFIX-home")
for ((mask=0; mask<64; mask++)); do
    TEST_PRESENT=''
    for ((i=0; i<6; i++)); do
        if ((mask & (1 << i))); then TEST_PRESENT+=" ${resources[i]}"; fi
    done
    for TEST_RUNNING in true false; do
        expected=absent
        if ((mask)); then expected=stopped; fi
        if ((mask & 1)) && [[ "$TEST_RUNNING" = true ]]; then expected=running; fi
        : > "$TEST_CALLS"
        success "$expected" cli status
        [[ $(wc -l < "$TEST_CALLS") -eq $((6 + (mask & 1))) ]] || fail 'incomplete inventory inspection'
    done
done

# Every existence error refuses, including one after a running dev was found.
TEST_PRESENT="${resources[*]}"
TEST_RUNNING=true
for TEST_FAULT in "${resources[@]}" inspect; do
    for TEST_PARTIAL in '' $'absent\n' $'true\n'; do failure cli status; done
done
TEST_FAULT=''
for TEST_RUNNING in '' garbage $'true\n' $'false\nextra' $'true\r'; do
    failure cli status
done
TEST_RUNNING=true

# Identity producers may fail after writing plausible bytes. No engine call
# or success record may follow, even when invoked through a conditional.
for tool in "$hash_tool" tr; do
    mv "$tmp/bin/$tool" "$tmp/bin/$tool.real"
    cat > "$tmp/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$TEST_PARTIAL"
exit 42
STUB
    chmod 755 "$tmp/bin/$tool"
    for TEST_PARTIAL in '' '123456789abc plausible'; do
        : > "$TEST_CALLS"
        failure cli status
        [[ ! -s "$TEST_CALLS" ]] || fail 'engine called after failed identity producer'
    done
    rm "$tmp/bin/$tool"
    mv "$tmp/bin/$tool.real" "$tmp/bin/$tool"
done

# Physical cwd identity is shared by symlink invocation. The default config
# file does not affect inventory.
ln -s "$tmp/project" "$tmp/alias"
cd "$tmp/alias"
success running cli status
[[ ! -e "$XDG_STATE_HOME" ]] || fail 'status created runtime state'
[[ $(cat "$tmp/project/jailbox.conf") = 'invalid configuration' ]] || fail 'configuration changed'
printf 'PASS: schema discovery, all inventory combinations, and discovery failures\n'
