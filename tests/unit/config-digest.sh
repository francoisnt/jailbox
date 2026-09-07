#!/bin/bash
# Version-bound configuration digest: canonical stream, golden vectors, key
# coverage, hash-tool portability, control-character framing, and the
# compatibility gate over surviving policy-bearing resources.
#
# Cases run the digest in subshells that export JAILBOX_CONFIG_* variables and
# override the version accessor; the overrides being subshell-local is the
# isolation mechanism, not an oversight.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/public-api.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/common.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/dev-image.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/container-runtime.sh"
# shellcheck disable=SC1091
source "$JAILBOX_DIR/host/config-digest.sh"

FIXTURE=$(mktemp -d)
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT

PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"

    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc"
        printf '     expected: %q\n' "$expected"
        printf '     actual:   %q\n' "$actual"
    fi
}

assert_ne() {
    local desc="$1" left="$2" right="$3"

    if [ "$left" != "$right" ]; then
        pass "$desc"
    else
        fail "$desc (both were $left)"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc"
        printf '     missing %q in: %s\n' "$needle" "$haystack"
    fi
}

# ── digest invocation ─────────────────────────────────────────────────────────
#
# Emit the stream or the digest for one effective configuration. The version
# accessor is replaced so vectors stay stable across stamped and unstamped
# checkouts; TEST_VERSION can be overridden per case like any other assignment.

TEST_VERSION_DEFAULT="1.2.3"

run_digest() {
    local emitter="$1" dir="$2" mode="$3"
    shift 3

    (
        PROJECT_DIR="$dir"
        SCRIPT_DIR="$JAILBOX_DIR"
        TEST_VERSION="$TEST_VERSION_DEFAULT"
        apply_config_defaults
        initialize_config_digest_state
        CONFIG_PATH_ARG=""
        DEV_IMAGE="" DEV_CONTAINERFILE=""
        SELECTED_DEV_CONTAINERFILE=""
        SELECTED_DEV_CONTAINERFILE_INPUT=""
        # shellcheck disable=SC2317 # Called indirectly by the digest stream.
        jailbox_version() { printf '%s' "$TEST_VERSION"; }
        for assignment in "$@"; do
            export "${assignment?}"
        done
        load_effective_config "" >/dev/null
        "$emitter" "$mode"
    )
}

digest_of() { run_digest config_digest_value "$@"; }
stream_of() { run_digest config_digest_stream "$@"; }

# Capture a refusal's diagnostic instead of its output.
digest_refusal() {
    local output status=0

    output=$(digest_of "$@" 2>&1 >/dev/null) || status=$?
    [ "$status" -ne 0 ] || { printf 'unexpectedly succeeded\n'; return 0; }
    printf '%s\n' "$output"
}

project_dir() {
    local dir

    dir=$(mktemp -d "$FIXTURE/project.XXXXXX")
    (cd "$dir" && pwd -P)
}

echo "── canonical stream and golden vectors ──"

VECTOR_DIR=$(project_dir)
VECTOR_ENV=(
    JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev:tag
    JAILBOX_CONFIG_EGRESS_ALLOW_0=b.example.com
    JAILBOX_CONFIG_EGRESS_ALLOW_1=a.example.com
    JAILBOX_CONFIG_EGRESS_ALLOW_2=b.example.com
    JAILBOX_CONFIG_READONLY_PATHS_0=z
    JAILBOX_CONFIG_READONLY_PATHS_1=a
)

# Hand-written canonical bytes. Every field separator is a literal TAB and every
# record ends with a newline; an empty scalar keeps its separator so the empty
# value stays an explicit field.
expected_stream=$(printf '%s\n' \
    'jailbox-config-digest-v1' \
    $'jailbox-version\t1.2.3' \
    $'scalar\tDEV_IMAGE\texample.invalid/dev:tag' \
    $'scalar\tDEV_CONTAINERFILE\t' \
    $'scalar\tDEV_BUILD_CONTEXT\t' \
    $'scalar\tDEV_TARGET_STAGE\t' \
    $'scalar\tMEMORY_LIMIT\t4g' \
    $'scalar\tCPU_LIMIT\t2' \
    $'scalar\tPIDS_LIMIT\t256' \
    $'array\tEGRESS_ALLOW\t2' \
    $'value\ta.example.com' \
    $'value\tb.example.com' \
    $'array\tREADONLY_PATHS\t2' \
    $'value\tz' \
    $'value\ta' \
    $'containerfile\tnone')

assert_eq "canonical stream is byte-exact" \
    "$expected_stream" "$(stream_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")"

# Golden digest for the stream above. Regenerate it deliberately whenever the
# digest inputs or encoding change; a change here is an ordinary within-release
# digest change, not a compatibility break, because the exact version is hashed.
GOLDEN_DIGEST="98aca97593e898b450413920d8670e4eed47137e4a274ed52a8babf5da714073"
assert_eq "golden digest vector" \
    "$GOLDEN_DIGEST" "$(digest_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")"

assert_eq "digest equals the hash of the canonical stream" \
    "$(printf '%s\n' "$expected_stream" | sha256sum | cut -d' ' -f1)" \
    "$GOLDEN_DIGEST"

echo "── ordering, sets, and defaults ──"

assert_eq "reordered and repeated EGRESS_ALLOW members are one set" \
    "$(digest_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")" \
    "$(digest_of "$VECTOR_DIR" launch \
        JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev:tag \
        JAILBOX_CONFIG_EGRESS_ALLOW_0=a.example.com \
        JAILBOX_CONFIG_EGRESS_ALLOW_1=b.example.com \
        JAILBOX_CONFIG_READONLY_PATHS_0=z \
        JAILBOX_CONFIG_READONLY_PATHS_1=a)"

assert_ne "reordered READONLY_PATHS change the digest" \
    "$(digest_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")" \
    "$(digest_of "$VECTOR_DIR" launch \
        JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev:tag \
        JAILBOX_CONFIG_EGRESS_ALLOW_0=a.example.com \
        JAILBOX_CONFIG_EGRESS_ALLOW_1=b.example.com \
        JAILBOX_CONFIG_READONLY_PATHS_0=a \
        JAILBOX_CONFIG_READONLY_PATHS_1=z)"

assert_eq "an explicitly spelled default equals an absent key" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
        JAILBOX_CONFIG_MEMORY_LIMIT=4g JAILBOX_CONFIG_CPU_LIMIT=2 \
        JAILBOX_CONFIG_PIDS_LIMIT=256 JAILBOX_CONFIG_EGRESS_ALLOW= \
        JAILBOX_CONFIG_READONLY_PATHS=)"

assert_ne "a changed scalar changes the digest" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
        JAILBOX_CONFIG_MEMORY_LIMIT=8g)"

assert_eq "empty arrays report count zero and emit no items" \
    $'array\tEGRESS_ALLOW\t0' \
    "$(stream_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img |
        grep -F 'EGRESS_ALLOW')"

comma_stream=$(stream_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
    JAILBOX_CONFIG_READONLY_PATHS_0='dir,with,commas' \
    JAILBOX_CONFIG_READONLY_PATHS_1='plain')
assert_eq "array items containing commas stay single items" \
    $'array\tREADONLY_PATHS\t2\nvalue\tdir,with,commas\nvalue\tplain' \
    "$(printf '%s\n' "$comma_stream" | grep -A2 -F 'READONLY_PATHS')"

echo "── version binding ──"

assert_ne "a different stamped release version changes the digest" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img TEST_VERSION=1.2.4)"

assert_ne "a development build differs from a stamped release" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img TEST_VERSION=dev)" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)"

# An unstamped source checkout and an install made from it share the 'dev'
# token, so identical remaining inputs produce one digest from either copy.
cp -R "$JAILBOX_DIR/host" "$FIXTURE/installed-host"
installed_digest=$(
    PROJECT_DIR="$VECTOR_DIR"
    SCRIPT_DIR="$FIXTURE"
    # shellcheck disable=SC1091
    source "$FIXTURE/installed-host/public-api.sh"
    # shellcheck disable=SC1091
    source "$FIXTURE/installed-host/common.sh"
    # shellcheck disable=SC1091
    source "$FIXTURE/installed-host/dev-image.sh"
    # shellcheck disable=SC1091
    source "$FIXTURE/installed-host/config-digest.sh"
    apply_config_defaults
    CONFIG_PATH_ARG=""
    export JAILBOX_CONFIG_DEV_IMAGE=img
    load_effective_config "" >/dev/null
    config_digest_value launch
)
assert_eq "an unstamped install matches its unstamped source checkout" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img TEST_VERSION=dev)" \
    "$installed_digest"

echo "── Containerfile identity ──"

CF_DIR=$(project_dir)
mkdir -p "$CF_DIR/nested"
printf 'FROM scratch\n' > "$CF_DIR/Containerfile"
printf 'FROM scratch\n' > "$CF_DIR/nested/Containerfile"

assert_eq "a discovered Containerfile is hashed by canonical path" \
    "containerfile"$'\t'"path"$'\t'"$CF_DIR/Containerfile" \
    "$(stream_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS= | tail -n1)"

assert_ne "the same content at a different in-project path is a different sandbox" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile)" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=nested/Containerfile)"

TWIN_DIR=$(project_dir)
printf 'FROM scratch\n' > "$TWIN_DIR/Containerfile"
assert_ne "identical content in another project is a different sandbox" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS=)" \
    "$(digest_of "$TWIN_DIR" launch JAILBOX_CONFIG_READONLY_PATHS=)"

# Explicit and implicit selection of one file record the same Containerfile
# identity. The digests still differ, because DEV_CONTAINERFILE keeps its
# configured spelling and discovery never mutates it.
assert_eq "an explicit selection records the identity discovery would" \
    "$(stream_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS= | tail -n1)" \
    "$(stream_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile | tail -n1)"
assert_eq "implicit discovery leaves the DEV_CONTAINERFILE scalar empty" \
    $'scalar\tDEV_CONTAINERFILE\t' \
    "$(stream_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS= |
        grep -F 'DEV_CONTAINERFILE')"
assert_ne "the configured DEV_CONTAINERFILE spelling stays a digest input" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS=)" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile)"

before_edit=$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile)
printf 'FROM alpine\n' > "$CF_DIR/Containerfile"
assert_eq "edited Containerfile bytes do not change the digest" \
    "$before_edit" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=Containerfile)"

assert_eq "DEV_IMAGE emits none without inspecting any Containerfile" \
    $'containerfile\tnone' \
    "$(stream_of "$CF_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
        JAILBOX_CONFIG_DEV_CONTAINERFILE=absent/Containerfile | tail -n1)"

EMPTY_DIR=$(project_dir)
assert_contains "launch refuses a missing implicit selection" \
    "$(digest_refusal "$EMPTY_DIR" launch JAILBOX_CONFIG_READONLY_PATHS=)" \
    "no Containerfile found"
assert_contains "launch refuses a missing explicit selection" \
    "$(digest_refusal "$EMPTY_DIR" launch JAILBOX_CONFIG_DEV_CONTAINERFILE=gone/Containerfile)" \
    "configured Containerfile does not exist"

assert_eq "attach records a vanished implicit selection as missing" \
    $'containerfile\tmissing' \
    "$(stream_of "$EMPTY_DIR" attach JAILBOX_CONFIG_READONLY_PATHS= | tail -n1)"
assert_eq "attach records a vanished explicit selection as missing" \
    $'containerfile\tmissing' \
    "$(stream_of "$EMPTY_DIR" attach JAILBOX_CONFIG_DEV_CONTAINERFILE=gone/Containerfile | tail -n1)"
assert_eq "attach and launch agree while the selection exists" \
    "$(digest_of "$CF_DIR" launch JAILBOX_CONFIG_READONLY_PATHS=)" \
    "$(digest_of "$CF_DIR" attach JAILBOX_CONFIG_READONLY_PATHS=)"

echo "── framing and control characters ──"

for label in tab newline; do
    case "$label" in
        tab) marker=$'\t' ;;
        newline) marker=$'\n' ;;
    esac
    control_dir="$FIXTURE/control${marker}project-$label"
    mkdir -p "$control_dir"
    printf 'FROM scratch\n' > "$control_dir/Containerfile"
    assert_contains "a $label in the project path is refused before serialization" \
        "$(digest_refusal "$control_dir" launch JAILBOX_CONFIG_READONLY_PATHS=)" \
        "control character"
done

stream_fields_are_clean=1
while IFS= read -r line; do
    IFS=$'\t' read -ra record_fields <<< "$line"
    for record_field in "${record_fields[@]}"; do
        contains_control_character "$record_field" && stream_fields_are_clean=0
    done
done <<< "$(stream_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")"
if [ "$stream_fields_are_clean" -eq 1 ]; then
    pass "no encoded field carries a control character"
else
    fail "no encoded field carries a control character"
fi

echo "── key coverage ──"

coverage_stream=$(stream_of "$VECTOR_DIR" launch "${VECTOR_ENV[@]}")
declare -A seen_records=()
coverage_ok=1
coverage_note=""
pending_key=""
pending_count=0
while IFS= read -r line; do
    case "$line" in
        scalar$'\t'*)
            key="${line#scalar$'\t'}"
            key="${key%%$'\t'*}"
            if [[ -v seen_records[$key] ]]; then
                coverage_ok=0
                coverage_note="duplicate record for $key"
            fi
            seen_records["$key"]=scalar
            ;;
        array$'\t'*)
            key="${line#array$'\t'}"
            pending_count="${key#*$'\t'}"
            key="${key%%$'\t'*}"
            if [[ -v seen_records[$key] ]]; then
                coverage_ok=0
                coverage_note="duplicate record for $key"
            fi
            seen_records["$key"]=array
            [[ "$pending_count" =~ ^(0|[1-9][0-9]*)$ ]] || {
                coverage_ok=0
                coverage_note="non-canonical count for $key"
            }
            pending_key="$key"
            ;;
        value$'\t'*)
            [ -n "$pending_key" ] || { coverage_ok=0; coverage_note="value record without an array"; }
            pending_count=$((pending_count - 1))
            [ "$pending_count" -ge 0 ] || { coverage_ok=0; coverage_note="more items than $pending_key declared"; }
            ;;
        *)
            if [ -n "$pending_key" ] && [ "$pending_count" -ne 0 ]; then
                coverage_ok=0
                coverage_note="fewer items than $pending_key declared"
            fi
            pending_key=""
            ;;
    esac
done <<< "$coverage_stream"

for key in "${CONFIG_SCALAR_KEYS[@]}"; do
    [ "${seen_records[$key]:-}" = scalar ] || {
        coverage_ok=0
        coverage_note="no scalar record for $key"
    }
done
for key in "${CONFIG_ARRAY_KEYS[@]}"; do
    [ "${seen_records[$key]:-}" = array ] || {
        coverage_ok=0
        coverage_note="no array record for $key"
    }
done
[ "${#seen_records[@]}" -eq $((${#CONFIG_SCALAR_KEYS[@]} + ${#CONFIG_ARRAY_KEYS[@]})) ] || {
    coverage_ok=0
    coverage_note="the stream carries records for undeclared keys"
}
if [ "$coverage_ok" -eq 1 ]; then
    pass "every machine configuration key has exactly one canonical record"
else
    fail "every machine configuration key has exactly one canonical record ($coverage_note)"
fi

for key in "${FRONTEND_SCALAR_KEYS[@]}"; do
    if [[ -v seen_records[$key] ]]; then
        fail "frontend-only key $key is never hashed"
    else
        pass "frontend-only key $key is never hashed"
    fi
done

set_keys_declared=1
for key in "${DIGEST_SET_ARRAY_KEYS[@]}"; do
    is_config_array_key "$key" || set_keys_declared=0
done
if [ "$set_keys_declared" -eq 1 ]; then
    pass "every DIGEST_SET_ARRAY_KEYS member is a declared array key"
else
    fail "every DIGEST_SET_ARRAY_KEYS member is a declared array key"
fi

echo "── hash tool portability ──"

mkdir -p "$FIXTURE/sha256sum-only" "$FIXTURE/shasum-only" "$FIXTURE/no-hash-tool"
ln -sf "$(command -v sha256sum)" "$FIXTURE/sha256sum-only/sha256sum"
assert_eq "sha256sum alone produces the vector digest" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)" \
    "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
        "PATH=$FIXTURE/sha256sum-only")"

if command -v shasum >/dev/null 2>&1; then
    ln -sf "$(command -v shasum)" "$FIXTURE/shasum-only/shasum"
    assert_eq "shasum -a 256 alone produces the same digest" \
        "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img)" \
        "$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
            "PATH=$FIXTURE/shasum-only")"
else
    echo "  ⏭️  shasum is not installed; skipping its portability vector"
fi

assert_contains "a host with neither tool refuses instead of guessing" \
    "$(digest_refusal "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
        "PATH=$FIXTURE/no-hash-tool")" \
    "sha256sum or shasum"

# The set-valued key is serialized through sort. A failure there must abort the
# digest rather than reduce the key to zero items, which would hash a truncated
# stream into a well-formed value and stop EGRESS_ALLOW changes from
# invalidating anything. DEV_IMAGE keeps sort off the rest of this path.
mkdir -p "$FIXTURE/failing-sort"
printf '#!/bin/sh\nexit 1\n' > "$FIXTURE/failing-sort/sort"
chmod +x "$FIXTURE/failing-sort/sort"
truncated_status=0
truncated_digest=$(digest_of "$VECTOR_DIR" launch JAILBOX_CONFIG_DEV_IMAGE=img \
    JAILBOX_CONFIG_EGRESS_ALLOW_0=b.example.com \
    JAILBOX_CONFIG_EGRESS_ALLOW_1=a.example.com \
    "PATH=$FIXTURE/failing-sort:$PATH" 2>/dev/null) || truncated_status=$?
if [ "$truncated_status" -ne 0 ] && [ -z "$truncated_digest" ]; then
    pass "a failed member serialization aborts instead of hashing a truncated stream"
else
    fail "a failed member serialization aborts instead of hashing a truncated stream" \
        "(status $truncated_status, digest '$truncated_digest')"
fi

echo "── compatibility gate ──"

mkdir -p "$FIXTURE/bin"
cat > "$FIXTURE/bin/podman" <<'EOF_PODMAN'
#!/bin/bash
# Fake Podman over a directory of resource files named <kind>.<name>, each
# holding LABEL=VALUE lines. Absent files are absent resources.
state="$FAKE_PODMAN_STATE"
file="$state/$1.$3"

case "$1 $2" in
    "container exists"|"volume exists"|"network exists")
        [ -f "$file" ]
        ;;
    "container inspect"|"volume inspect"|"network inspect")
        [ -f "$file" ] || exit 1
        label=$(printf '%s' "$5" | sed -n 's/.*index [^ ]* "\([^"]*\)".*/\1/p')
        [ -n "$label" ] || exit 1
        sed -n "s|^$label=||p" "$file"
        ;;
    *) exit 1 ;;
esac
EOF_PODMAN
chmod +x "$FIXTURE/bin/podman"

GATE_DIGEST=$(printf 'gate' | sha256sum | cut -d' ' -f1)
OTHER_DIGEST=$(printf 'other' | sha256sum | cut -d' ' -f1)

gate_state() {
    local dir

    dir=$(mktemp -d "$FIXTURE/gate.XXXXXX")
    printf '%s\n' "$dir"
}

put_resource() {
    printf '%s\n' "${3:-}" > "$1/$2"
}

run_compatibility_gate() {
    (
        PATH="$FIXTURE/bin:$PATH"
        export FAKE_PODMAN_STATE="$1"
        PROJECT_DIR="$FIXTURE"
        CONTAINER_NAME="jailbox-gate"
        PROXY_NAME="jailbox-gate-proxy"
        NETWORK_NAME="jailbox-gate-net"
        CONFIG_DIGEST="$GATE_DIGEST"
        CONFIG_DIGEST_LABEL_ARGS=(--label "$CONFIG_DIGEST_LABEL=$CONFIG_DIGEST")
        require_compatible_project_resources
    ) 2>&1
}

assert_gate_accepts() {
    local desc="$1" state="$2" output status=0

    output=$(run_compatibility_gate "$state") || status=$?
    if [ "$status" -eq 0 ]; then
        pass "$desc"
    else
        fail "$desc ($output)"
    fi
}

assert_gate_refuses() {
    local desc="$1" state="$2"
    shift 2
    local output status=0 needle

    output=$(run_compatibility_gate "$state") || status=$?
    if [ "$status" -eq 0 ]; then
        fail "$desc (the gate accepted it)"
        return
    fi
    for needle in "$@"; do
        if [[ "$output" != *"$needle"* ]]; then
            fail "$desc (diagnostic lacks '$needle': $output)"
            return
        fi
    done
    pass "$desc"
}

state=$(gate_state)
assert_gate_accepts "an empty project accepts the current digest" "$state"

state=$(gate_state)
for resource in container.jailbox-gate container.jailbox-gate-proxy \
    network.jailbox-gate-net network.jailbox-gate-net-internal \
    network.jailbox-gate-net-external; do
    put_resource "$state" "$resource" "jailbox.config-digest=$GATE_DIGEST"
done
assert_gate_accepts "a complete matching inventory is compatible" "$state"

put_resource "$state" volume.jailbox-gate-home "jailbox.project=$FIXTURE"
assert_gate_accepts "the home volume is outside the digest inventory" "$state"

state=$(gate_state)
put_resource "$state" network.jailbox-gate-net "jailbox.project=$FIXTURE"
assert_gate_refuses "an unlabeled network is incompatible" "$state" \
    "no configuration digest label" "jailbox --clean"

state=$(gate_state)
put_resource "$state" network.jailbox-gate-net "jailbox.config-digest=not-a-digest"
assert_gate_refuses "a malformed digest label is incompatible" "$state" \
    "malformed configuration digest label" "jailbox --clean"

state=$(gate_state)
put_resource "$state" container.jailbox-gate "jailbox.config-digest=$OTHER_DIGEST"
assert_gate_refuses "a mismatched container refuses with stop guidance" "$state" \
    "container 'jailbox-gate'" "jailbox stop"

state=$(gate_state)
put_resource "$state" container.jailbox-gate "jailbox.config-digest=$GATE_DIGEST"
put_resource "$state" container.jailbox-gate-proxy "jailbox.config-digest=$OTHER_DIGEST"
assert_gate_refuses "an inconsistent pair of containers refuses" "$state" \
    "container 'jailbox-gate-proxy'" "jailbox stop"

# The plain network is the only one a proxy-less configuration requests; a
# stale internal network from the other mode must still refuse.
state=$(gate_state)
put_resource "$state" network.jailbox-gate-net "jailbox.config-digest=$GATE_DIGEST"
put_resource "$state" network.jailbox-gate-net-internal "jailbox.config-digest=$OTHER_DIGEST"
assert_gate_refuses "a stale network outside the requested mode refuses" "$state" \
    "network 'jailbox-gate-net-internal'" "jailbox --clean"

state=$(gate_state)
put_resource "$state" container.jailbox-gate "jailbox.config-digest=$OTHER_DIGEST"
put_resource "$state" network.jailbox-gate-net-external "jailbox.config-digest=$OTHER_DIGEST"
assert_gate_refuses "every incompatible member is named" "$state" \
    "container 'jailbox-gate'" "network 'jailbox-gate-net-external'" "jailbox --clean"

echo ""
echo "Configuration digest: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
