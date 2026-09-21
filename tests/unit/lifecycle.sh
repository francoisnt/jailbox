#!/bin/bash
# Exact-name lifecycle: `stop`, `--clean`, launch compatibility, and the
# SHA-256 identity every one of them derives before touching a resource.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAILBOX_DIR="$(cd "$TEST_DIR/../.." && pwd)"
FIXTURE=$(mktemp -d)
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
PASSED=0
FAILED=0

pass() { echo "  ✅ $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  ❌ $*"; FAILED=$((FAILED + 1)); }

# Fake Podman backed by a directory of resource files. Each file is named
# <kind>.<name> and holds that resource's LABEL=VALUE lines, empty for an
# unlabeled resource. Removals delete the file, so surviving files are the
# assertion.
mkdir -p "$FIXTURE/bin"
cp "$JAILBOX_DIR/tests/fixtures/lifecycle-podman.sh" "$FIXTURE/bin/podman"
chmod +x "$FIXTURE/bin/podman"

# Sets PROJECT, PREFIX, STATE_DIR, and FAKE_PODMAN_STATE for the caller, so it
# must not run in a subshell.
new_project() {
    PROJECT=$(mktemp -d "$FIXTURE/project.XXXXXX")
    unset JAILBOX_CONFIG_DEV_IMAGE JAILBOX_CONFIG_EPHEMERAL_HOME
    printf "READONLY_PATHS=\n" > "$PROJECT/jailbox.conf"
    FAKE_PODMAN_STATE="$PROJECT/.podman-state"
    mkdir -p "$FAKE_PODMAN_STATE"
    export FAKE_PODMAN_STATE
    PREFIX=$(source "$JAILBOX_DIR/src/host/core/project-id.sh" && jailbox_resource_prefix_for_path "$PROJECT")
    STATE_DIR="$FIXTURE/xdg-state/jailbox/projects/$(source "$JAILBOX_DIR/src/host/core/project-id.sh" && jailbox_project_hash_for_path "$PROJECT")"
}

# Declare a resource in the fake Podman state: kind, name, optional label
# lines. Resources are declared unlabeled by default: nothing in the lifecycle
# path may consult a label to decide what it owns.
declare_resource() {
    printf '%s' "${3:-}" > "$FAKE_PODMAN_STATE/$1.$2"
}

resource_present() {
    [ -f "$FAKE_PODMAN_STATE/$1.$2" ]
}

actions() {
    cat "$FAKE_PODMAN_STATE/actions" 2>/dev/null || true
}

run_jailbox() {
    local project="$1"
    shift
    (
        cd "$project" || exit 1
        XDG_STATE_HOME="$FIXTURE/xdg-state" PATH="$FIXTURE/bin:$PATH" \
            "$JAILBOX_DIR/src/jailbox" "$@"
    ) 2>&1
}

test_stop_removes_both_project_containers() {
    local project output

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX"
    declare_resource container "$PREFIX-proxy"
    declare_resource volume "$PREFIX-home"
    declare_resource network "$PREFIX-net"
    mkdir -p "$STATE_DIR"
    printf 'key\n' > "$STATE_DIR/key"
    printf 'identity\n' > "$STATE_DIR/gitconfig"

    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds against a present sandbox"
    else
        fail "stop succeeds against a present sandbox (got: $output)"
    fi
    if ! resource_present container "$PREFIX" && ! resource_present container "$PREFIX-proxy"; then
        pass "stop removes both project containers"
    else
        fail "stop removes both project containers"
    fi
    if resource_present volume "$PREFIX-home" && ! resource_present network "$PREFIX-net"; then
        pass "stop preserves the legacy home and removes the project network"
    else
        fail "stop preserves the legacy home and removes the project network"
    fi
    if [ ! -e "$STATE_DIR/key" ] && [ -f "$STATE_DIR/gitconfig" ]; then
        pass "stop removes legacy credentials and preserves unrelated state"
    else
        fail "stop removes legacy credentials and preserves unrelated state"
    fi
}

test_stop_is_idempotent_and_partial_safe() {
    local project output

    new_project
    project="$PROJECT"
    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds when both containers are absent"
    else
        fail "stop succeeds when both containers are absent (got: $output)"
    fi

    declare_resource container "$PREFIX-proxy"
    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds when only the proxy exists"
    else
        fail "stop succeeds when only the proxy exists (got: $output)"
    fi
    resource_present container "$PREFIX-proxy" && fail "stop removed the lone proxy container"

    if output=$(run_jailbox "$project" stop); then
        pass "repeated stop succeeds"
    else
        fail "repeated stop succeeds (got: $output)"
    fi
}

# Deletion depends on the exact derived name alone. Provenance is not
# consulted, so a container carrying a foreign label, another project's label,
# or no label at all is removed exactly like one jailbox created.
test_stop_removes_any_occupant_of_the_derived_names() {
    local project output labels description

    while IFS='|' read -r description labels; do
        new_project
        project="$PROJECT"
        declare_resource container "$PREFIX"
        declare_resource container "$PREFIX-proxy" "$labels"

        if output=$(run_jailbox "$project" stop); then
            pass "stop succeeds against a proxy-name occupant with $description"
        else
            fail "stop succeeds against a proxy-name occupant with $description (got: $output)"
        fi
        if ! resource_present container "$PREFIX" && ! resource_present container "$PREFIX-proxy"; then
            pass "stop removes a proxy-name occupant with $description"
        else
            fail "stop removes a proxy-name occupant with $description"
        fi
    done <<'EOF_CASES'
a foreign project label|jailbox.project=/somewhere/else
no labels at all|
an unrelated label|com.example.owner=someone
EOF_CASES
}

test_lifecycle_fails_closed_on_exists_errors() {
    local project output kind command

    for kind in container volume network image; do
        new_project
        project="$PROJECT"
        mkdir -p "$STATE_DIR"
        printf 'key\n' > "$STATE_DIR/key"
        command=--clean
        [ "$kind" != container ] || command=stop

        output=$(FAKE_PODMAN_EXISTS_ERROR_KIND="$kind" run_jailbox "$project" "$command" || true)
        case "$output" in
            *"could not determine whether $kind"*"Podman"*)
                pass "$command fails closed when a $kind existence probe errors"
                ;;
            *)
                fail "$command fails closed when a $kind existence probe errors (got: $output)"
                ;;
        esac
        if [ -f "$STATE_DIR/key" ] && [ -z "$(actions)" ]; then
            pass "a $kind existence error prevents all lifecycle mutation"
        else
            fail "a $kind existence error prevents all lifecycle mutation (actions: $(actions))"
        fi
    done
}

test_stop_ignores_configuration() {
    local project output

    new_project
    project="$PROJECT"
    printf 'NOT A CONFIG\n' > "$project/jailbox.conf"
    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds with a malformed config"
    else
        fail "stop succeeds with a malformed config (got: $output)"
    fi

    chmod 000 "$project/jailbox.conf"
    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds with an unreadable config"
    else
        fail "stop succeeds with an unreadable config (got: $output)"
    fi
    chmod 600 "$project/jailbox.conf"

    rm "$project/jailbox.conf"
    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds with no config at all"
    else
        fail "stop succeeds with no config at all (got: $output)"
    fi
}

# stop is a precondition for launch, so it must not inherit launch's toolchain.
test_stop_requires_podman_only() {
    local project restricted tool resolved forbidden excluded output

    restricted="$FIXTURE/restricted-bin"
    mkdir -p "$restricted"
    cp "$FIXTURE/bin/podman" "$restricted/podman"
    for tool in bash sh dirname basename tr cut sed awk grep cat id mktemp rm find sha256sum shasum; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$restricted/$tool"
    done

    excluded=1
    for forbidden in ssh ssh-keygen realpath cksum code codium; do
        [ ! -e "$restricted/$forbidden" ] || excluded=0
    done
    if [ "$excluded" -eq 1 ]; then
        pass "restricted PATH excludes the launch toolchain"
    else
        fail "restricted PATH excludes the launch toolchain"
    fi

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX"
    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/src/jailbox" stop) 2>&1 || true)
    if ! resource_present container "$PREFIX"; then
        pass "stop succeeds without SSH tooling, realpath, cksum, or an editor"
    else
        fail "stop succeeds without SSH tooling, realpath, cksum, or an editor (got: $output)"
    fi

    rm "$restricted/podman"
    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/src/jailbox" stop) 2>&1 || true)
    case "$output" in
        *"required command not found: podman"*) pass "stop still requires podman" ;;
        *) fail "stop still requires podman (got: $output)" ;;
    esac
    cp "$FIXTURE/bin/podman" "$restricted/podman"
}

test_clean_removes_every_derived_target() {
    local project output name

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX"
    declare_resource container "$PREFIX-proxy"
    declare_resource volume "$PREFIX-home"
    for name in net net-internal net-external; do
        declare_resource network "$PREFIX-$name"
    done
    mkdir -p "$STATE_DIR"
    printf 'key\n' > "$STATE_DIR/key"

    if output=$(run_jailbox "$project" --clean); then
        pass "--clean succeeds against a fully populated project"
    else
        fail "--clean succeeds against a fully populated project (got: $output)"
    fi
    if [ -z "$(find "$FAKE_PODMAN_STATE" -maxdepth 1 -name 'container.*' -o -maxdepth 1 -name 'volume.*' -o -maxdepth 1 -name 'network.*')" ]; then
        pass "--clean removes containers, the home volume, and all project networks"
    else
        fail "--clean removes containers, the home volume, and all project networks"
    fi
    if [ ! -d "$STATE_DIR" ]; then
        pass "--clean removes the project SSH state"
    else
        fail "--clean removes the project SSH state"
    fi

    if output=$(run_jailbox "$project" --clean); then
        pass "--clean remains idempotent when every target is absent"
    else
        fail "--clean remains idempotent when every target is absent (got: $output)"
    fi
}

# The same exact-name contract across every resource type --clean deletes.
test_clean_removes_foreign_targets_of_any_type() {
    local project output kind name

    for kind in volume network; do
        new_project
        project="$PROJECT"
        case "$kind" in
            volume) name="$PREFIX-home" ;;
            network) name="$PREFIX-net-external" ;;
        esac

        declare_resource container "$PREFIX"
        declare_resource volume "$PREFIX-home"
        declare_resource network "$PREFIX-net-external"
        declare_resource "$kind" "$name" "jailbox.project=/somewhere/else"
        mkdir -p "$STATE_DIR"
        printf 'key\n' > "$STATE_DIR/key"

        if output=$(run_jailbox "$project" --clean); then
            pass "--clean succeeds with a foreign-labelled $kind on a derived name"
        else
            fail "--clean succeeds with a foreign-labelled $kind on a derived name (got: $output)"
        fi
        if ! resource_present "$kind" "$name" && ! resource_present container "$PREFIX"; then
            pass "--clean removes the foreign-labelled $kind and every other derived name"
        else
            fail "--clean removes the foreign-labelled $kind and every other derived name"
        fi
        if [ ! -d "$STATE_DIR" ]; then
            pass "--clean still removes the project SSH state alongside a foreign $kind"
        else
            fail "--clean still removes the project SSH state alongside a foreign $kind"
        fi
    done
}

# Nothing outside the derived names is a removal target, whatever it is
# labelled — including the sandbox of an unrelated project.
test_clean_leaves_undeclared_names_alone() {
    local project output

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX"
    declare_resource container "jailbox-other-0123456789ab" "jailbox.project=$project"
    declare_resource volume "jailbox-other-0123456789ab-home" "jailbox.project=$project"
    declare_resource network "jailbox-other-0123456789ab-net" "jailbox.project=$project"

    if output=$(run_jailbox "$project" --clean); then
        pass "--clean succeeds beside resources on unrelated names"
    else
        fail "--clean succeeds beside resources on unrelated names (got: $output)"
    fi
    if resource_present container "jailbox-other-0123456789ab" &&
        resource_present volume "jailbox-other-0123456789ab-home" &&
        resource_present network "jailbox-other-0123456789ab-net"; then
        pass "--clean leaves every name outside this project's derived set untouched"
    else
        fail "--clean leaves every name outside this project's derived set untouched (actions: $(actions))"
    fi
}

# Legacy containers refuse at the digest gate after configuration validation.
test_launch_rejects_legacy_containers() {
    local project output name labels description

    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE/bin/codium"
    chmod +x "$FIXTURE/bin/codium"

    for name in "" -proxy; do
        for description in "this project's label" "a foreign project label" "no labels at all"; do
            new_project
            project="$PROJECT"
            export JAILBOX_CONFIG_DEV_IMAGE=localhost/fixture
            case "$description" in
                "this project's label") labels="jailbox.project=$project" ;;
                "a foreign project label") labels="jailbox.project=/somewhere/else" ;;
                *) labels="" ;;
            esac
            declare_resource container "$PREFIX$name" "$labels"
            output=$(run_jailbox "$project" up || true)
            case "$output" in
                *"jailbox stop"*)
                    pass "launch names jailbox stop for a ${name:-development} container with $description"
                    ;;
                *)
                    fail "launch names jailbox stop for a ${name:-development} container with $description (got: $output)"
                    ;;
            esac
            case "$output" in
                *"does not own"*)
                    fail "launch no longer distinguishes owned from foreign ${name:-development} containers"
                    ;;
                *)
                    pass "launch gives one diagnostic for a ${name:-development} container with $description"
                    ;;
            esac
            if resource_present container "$PREFIX$name" && [ -z "$(actions)" ]; then
                pass "the ${name:-development} container with $description is left untouched"
            else
                fail "the ${name:-development} container with $description is left untouched"
            fi
        done
    done
    rm "$FIXTURE/bin/codium"
}

# Configuration must be valid before launch can decide whether a live sandbox
# is compatible. Its presence no longer implies a stop precondition.
test_configuration_precedes_convergence() {
    local project output

    new_project
    project="$PROJECT"
    export JAILBOX_CONFIG_EPHEMERAL_HOME=invalid
    declare_resource container "$PREFIX"

    output=$(run_jailbox "$project" up || true)
    case "$output" in
        *"invalid EPHEMERAL_HOME"*) pass "launch validates configuration before convergence" ;;
        *) fail "launch validates configuration before convergence (got: $output)" ;;
    esac
    case "$output" in
        *"jailbox stop"*) fail "no absence-only refusal before configuration" ;;
        *) pass "no absence-only refusal before configuration" ;;
    esac

    run_jailbox "$project" stop >/dev/null
    output=$(run_jailbox "$project" up || true)
    case "$output" in
        *"invalid EPHEMERAL_HOME"*)
            pass "the next launch after stopping reports the configuration error"
            ;;
        *)
            fail "the next launch after stopping reports the configuration error (got: $output)"
            ;;
    esac
}

test_launch_reports_missing_podman_first() {
    local project restricted tool resolved output

    restricted="$FIXTURE/no-podman-bin"
    mkdir -p "$restricted"
    # Link only the tools needed to reach the launch dependency check. Adding
    # a system directory to PATH is not safe here: Podman commonly lives
    # beside sed and the test would accidentally expose the command it is
    # meant to exclude.
    for tool in bash dirname basename tr cut sed sha256sum shasum; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$restricted/$tool"
    done
    new_project
    project="$PROJECT"
    output=$( (cd "$project" && PATH="$restricted" \
        XDG_STATE_HOME="$FIXTURE/xdg-state" "$JAILBOX_DIR/src/jailbox" up) 2>&1 || true)
    case "$output" in
        *"required command not found: podman"*)
            pass "machine up reports missing podman before probing container names"
            ;;
        *)
            fail "machine up reports missing podman before probing container names (got: $output)"
            ;;
    esac
}

# cksum is only needed by the wrapper image build. Every command that never
# builds an image must work without it.
test_cksum_is_required_only_by_launch() {
    local project restricted tool resolved output command

    restricted="$FIXTURE/no-cksum-bin"
    mkdir -p "$restricted"
    cp "$FIXTURE/bin/podman" "$restricted/podman"
    for tool in bash sh dirname basename tr cut sed awk grep cat id mktemp rm find sha256sum realpath ssh ssh-keygen; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$restricted/$tool"
    done
    if [ ! -e "$restricted/cksum" ] && [ -e "$restricted/sha256sum" ]; then
        pass "restricted PATH has sha256sum but no cksum"
    else
        fail "restricted PATH has sha256sum but no cksum"
    fi

    new_project
    project="$PROJECT"
    for command in stop status ssh-config --clean; do
        if output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
            "$JAILBOX_DIR/src/jailbox" "$command") 2>&1); then
            pass "$command succeeds without cksum"
        else
            fail "$command succeeds without cksum (got: $output)"
        fi
    done

    # In a source checkout --uninstall stops at the install-copy check; reaching
    # that message proves it required neither Podman nor a hash tool.
    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/src/jailbox" --uninstall) 2>&1 || true)
    case "$output" in
        *"not an installed copy"*) pass "--uninstall reaches the installer without cksum" ;;
        *) fail "--uninstall reaches the installer without cksum (got: $output)" ;;
    esac

    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/src/jailbox" up) 2>&1 || true)
    case "$output" in
        *"required command not found: cksum"*)
            pass "machine up still requires cksum before building the wrapper image"
            ;;
        *)
            fail "machine up still requires cksum before building the wrapper image (got: $output)"
            ;;
    esac
}

test_uninstall_needs_no_podman_or_hash_tool() {
    local project restricted tool resolved output

    restricted="$FIXTURE/uninstall-bin"
    mkdir -p "$restricted"
    for tool in bash dirname basename readlink cat mktemp; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$restricted/$tool"
    done
    new_project
    project="$PROJECT"
    printf 'NOT A CONFIG\n' > "$project/jailbox.conf"

    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/src/jailbox" --uninstall) 2>&1 || true)
    case "$output" in
        *"not an installed copy"*)
            pass "--uninstall runs without podman, a hash tool, or a valid config"
            ;;
        *)
            fail "--uninstall runs without podman, a hash tool, or a valid config (got: $output)"
            ;;
    esac
}

test_stop_documented_in_help() {
    local project output

    new_project
    project="$PROJECT"
    output=$(run_jailbox "$project" --help)
    case "$output" in
        *"Usage:"*"|stop|"*) pass "stop appears in the literal usage synopsis" ;;
        *) fail "stop appears in the literal usage synopsis (got: $output)" ;;
    esac
    case "$output" in
        *"stop"*"Stop and remove this project's jailbox containers"*)
            pass "stop appears in the generated options block"
            ;;
        *)
            fail "stop appears in the generated options block (got: $output)"
            ;;
    esac
}

test_up_documented_in_help() {
    local project output

    new_project
    project="$PROJECT"
    output=$(run_jailbox "$project" --help)
    case "$output" in
        *"Usage:"*"[up|"*) pass "up appears in the literal usage synopsis" ;;
        *) fail "up appears in the literal usage synopsis (got: $output)" ;;
    esac
    case "$output" in
        *"up"*"Launch the sandbox using environment configuration"*)
            pass "up appears in the generated options block"
            ;;
        *) fail "up appears in the generated options block (got: $output)" ;;
    esac
}

test_up_ignores_editor_environment_override() {
    local project output

    new_project
    project="$PROJECT"
    export JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev
    output=$(JAILBOX_EDITOR=not-an-editor run_jailbox "$project" up || true)
    case "$output" in
        *"invalid EDITOR="*|*"neither 'codium' nor 'code'"*)
            fail "up ignores the editor environment override (got: $output)"
            ;;
        *"Using dev image: example.invalid/dev"*)
            pass "up ignores the editor environment override and enters the shared launch core"
            ;;
        *)
            fail "up ignores the editor environment override and enters the shared launch core (got: $output)"
            ;;
    esac
}

# Populate a PATH directory with podman and the named tools only, so a run
# through it proves exactly which dependencies the command still has.
make_restricted_bin() {
    local dir tool resolved

    dir="$FIXTURE/$1"
    shift
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$FIXTURE/bin/podman" "$dir/podman"
    for tool in "$@"; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$dir/$tool"
    done
    printf '%s\n' "$dir"
}

# Identity is derived before general preflight, so every command that needs a
# derived name must report the missing hash tool by itself — naming both
# supported alternatives — and must mutate nothing on the way there.
test_identity_requires_a_sha256_tool() {
    local project restricted output command

    restricted=$(make_restricted_bin no-hash-bin \
        bash sh dirname basename tr cut sed awk grep cat id mktemp rm find \
        realpath ssh ssh-keygen cksum)
    if [ ! -e "$restricted/sha256sum" ] && [ ! -e "$restricted/shasum" ]; then
        pass "restricted PATH has neither sha256sum nor shasum"
    else
        fail "restricted PATH has neither sha256sum nor shasum"
    fi

    for command in stop --clean status connection-info ssh-config up; do
        new_project
        project="$PROJECT"
        declare_resource container "$PREFIX"
        mkdir -p "$STATE_DIR"
        printf 'key\n' > "$STATE_DIR/key"

        output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
            "$JAILBOX_DIR/src/jailbox" $command) 2>&1 || true)
        case "$output" in
            *"sha256sum or shasum"*)
                pass "${command:-launch} names both SHA-256 alternatives when neither is installed"
                ;;
            *)
                fail "${command:-launch} names both SHA-256 alternatives when neither is installed (got: $output)"
                ;;
        esac
        if resource_present container "$PREFIX" && [ -z "$(actions)" ] && [ -f "$STATE_DIR/key" ]; then
            pass "${command:-launch} touches no resource without a SHA-256 tool"
        else
            fail "${command:-launch} touches no resource without a SHA-256 tool (actions: $(actions))"
        fi
    done
}

# The CLI canonicalizes the project directory with `pwd -P`, so equivalent
# spellings of one directory must derive one identity. Existing SHA-256-derived
# names therefore need no migration.
test_identity_is_stable_across_path_spellings() {
    local project relative link output spelling

    new_project
    project="$PROJECT"
    relative=$(basename "$project")
    link="$FIXTURE/link-to-project"
    ln -sfn "$project" "$link"

    for spelling in absolute relative dotted symlinked; do
        declare_resource container "$PREFIX"
        output=$( (
            case "$spelling" in
                absolute) cd "$project" ;;
                relative) cd "$FIXTURE" && cd "$relative" ;;
                dotted) cd "$FIXTURE" && cd "./$relative/." ;;
                symlinked) cd "$link" ;;
            esac || exit 1
            XDG_STATE_HOME="$FIXTURE/xdg-state" PATH="$FIXTURE/bin:$PATH" \
                "$JAILBOX_DIR/src/jailbox" stop
        ) 2>&1 ) || true
        if ! resource_present container "$PREFIX"; then
            pass "the $spelling spelling derives the same container name"
        else
            fail "the $spelling spelling derives the same container name (got: $output)"
        fi
    done
    rm -f "$link"
}

# Both supported tools compute the same SHA-256, so a host with either one
# reaches the same project resources.
test_both_sha256_tools_produce_the_same_identity() {
    local project restricted output tool
    local -a common=(bash sh dirname basename tr cut sed awk grep cat id mktemp rm find)

    for tool in sha256sum shasum; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "  ⏭️  $tool is not installed; skipping its identity vector"
            continue
        fi
        restricted=$(make_restricted_bin "only-$tool" "${common[@]}" "$tool")
        new_project
        project="$PROJECT"
        declare_resource container "$PREFIX"

        output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
            "$JAILBOX_DIR/src/jailbox" stop) 2>&1 || true)
        if ! resource_present container "$PREFIX"; then
            pass "$tool alone derives the shared project identity"
        else
            fail "$tool alone derives the shared project identity (got: $output)"
        fi
    done
}

test_launch_runs_without_replace() {
    if grep -Fq -- '--replace' "$JAILBOX_DIR/src/host/core/container-runtime.sh" ||
        grep -Fq -- '--replace' "$JAILBOX_DIR/src/host/core/network.sh"; then
        fail "development and proxy runs do not use --replace"
    else
        pass "development and proxy runs do not use --replace"
    fi
    if grep -Fq 'Replacing existing' "$JAILBOX_DIR/src/host/core/container-runtime.sh" ||
        grep -Fq 'Replacing existing' "$JAILBOX_DIR/src/host/core/network.sh"; then
        fail "dead replacement notices are removed"
    else
        pass "dead replacement notices are removed"
    fi
}

test_home_retention_and_inspection() {
    local policy output status

    for policy in legacy false true corrupt empty; do
        new_project
        declare_resource container "$PREFIX"
        declare_resource container "$PREFIX-proxy"
        declare_resource network "$PREFIX-net"
        declare_resource network "$PREFIX-net-internal"
        declare_resource network "$PREFIX-net-external"
        declare_resource image "$PREFIX-dev"
        case "$policy" in
            legacy) declare_resource volume "$PREFIX-home" ;;
            empty) declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=' ;;
            *) declare_resource volume "$PREFIX-home" "jailbox.ephemeral-home=$policy" ;;
        esac
        output=$(JAILBOX_CONFIG_EPHEMERAL_HOME=invalid run_jailbox "$PROJECT" stop)
        if ! resource_present container "$PREFIX" && ! resource_present container "$PREFIX-proxy" &&
            ! resource_present network "$PREFIX-net" && ! resource_present network "$PREFIX-net-internal" &&
            ! resource_present network "$PREFIX-net-external" && resource_present image "$PREFIX-dev"; then
            pass "stop clears containers/networks and preserves images for $policy"
        else
            fail "stop inventory for $policy"
        fi
        if { [ "$policy" = true ] && ! resource_present volume "$PREFIX-home"; } ||
            { [ "$policy" != true ] && resource_present volume "$PREFIX-home"; }; then
            pass "stop follows stored $policy policy despite invalid requested configuration"
        else
            fail "stored retention for $policy"
        fi
        if [[ "$policy" != corrupt && "$policy" != empty ]] || [[ "$output" == *"corrupt"*"preserving"* ]]; then
            pass "corrupt metadata warning for $policy"
        else
            fail "corrupt metadata warning for $policy"
        fi
    done

    new_project
    declare_resource container "$PREFIX"
    declare_resource network "$PREFIX-net"
    declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=true'
    status=0
    output=$(FAKE_PODMAN_INSPECT_ERROR_KIND=volume run_jailbox "$PROJECT" stop) || status=$?
    if [ "$status" -ne 0 ] && [ -z "$(actions)" ] && [[ "$output" == *"could not inspect retention metadata"* ]]; then
        pass "home inspection failure aborts stop before any deletion"
    else
        fail "home inspection failure aborts stop (got: $output)"
    fi
    if [[ "$output" != *"jailbox --clean"* && "$output" != *"corrupt"* ]]; then
        pass "failed retention inspection does not imply corruption or recommend destructive recovery"
    else
        fail "failed retention inspection gives unsupported recovery advice (got: $output)"
    fi
    if FAKE_PODMAN_INSPECT_ERROR_KIND=volume run_jailbox "$PROJECT" --clean >/dev/null; then
        pass "clean does not require retention inspection"
    else
        fail "clean does not require retention inspection"
    fi
}

test_home_recovery() {
    local policy requested output status recovery

    for policy in legacy false true corrupt empty; do
        for requested in false true; do
            new_project
            export JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev JAILBOX_CONFIG_EPHEMERAL_HOME=$requested
            case "$policy" in
                legacy) declare_resource volume "$PREFIX-home" ;;
                empty) declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=' ;;
                *) declare_resource volume "$PREFIX-home" "jailbox.ephemeral-home=$policy" ;;
            esac
            # A second, digest-bearing refusal must not hide home recovery.
            declare_resource network "$PREFIX-net" 'jailbox.config-digest=stale'
            if [[ "$policy" == legacy || "$policy" == false ]] && [ "$requested" = false ]; then
                rm "$FAKE_PODMAN_STATE/network.$PREFIX-net"
            fi
            output=$(run_jailbox "$PROJECT" up || true)
            recovery=--clean
            if [[ "$policy" == legacy || "$policy" == false ]] && [ "$requested" = false ]; then
                if [[ "$output" == *"Using dev image"* ]] && [ -z "$(actions)" ]; then
                    pass "$policy home is reusable under false without relabeling"
                else
                    fail "$policy home reuse (got: $output)"
                fi
                continue
            elif [ "$policy" = true ]; then
                recovery=stop
            fi
            if [[ "$output" == *"jailbox $recovery"* ]] && [ -z "$(actions)" ]; then
                pass "$policy under $requested refuses without mutation and names $recovery"
            else
                fail "$policy under $requested refusal (got: $output)"
            fi
            if [ "$recovery" != --clean ] || [[ "$output" == *"permanently deletes"*"home and runtime state"* ]]; then
                pass "$policy recovery includes required data-loss warning"
            else
                fail "$policy recovery warning"
            fi
            run_jailbox "$PROJECT" "$recovery" >/dev/null
            output=$(run_jailbox "$PROJECT" up || true)
            if [[ "$output" == *"Using dev image"* ]] && ! resource_present volume "$PREFIX-home"; then
                pass "$recovery resolves $policy refusal under $requested"
            else
                fail "recovery leaves $policy blocked (got: $output)"
            fi
        done
    done

    new_project
    export JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev JAILBOX_CONFIG_EPHEMERAL_HOME=invalid
    status=0
    output=$(run_jailbox "$PROJECT" up) || status=$?
    if [ "$status" -eq 1 ] && [ -z "$(actions)" ] && [[ "$output" == *"invalid EPHEMERAL_HOME"* ]]; then
        pass "invalid home mode exits 1 before lifecycle mutation"
    else
        fail "invalid home mode refusal (got: $output)"
    fi
}

# These fixtures intentionally isolate configuration and project state.
# shellcheck disable=SC2030
run_home_function() (
    # Exercise creation/reuse at the owning layer, without a complete fake
    # image build/SSH stack. The CLI refusal cases above test dispatch wiring.
    # shellcheck disable=SC1091
    source "$JAILBOX_DIR/src/public.sh"
    # shellcheck source=src/host/api-support.sh
    source "$JAILBOX_DIR/src/host/api-support.sh"
    initialize_public_api_lookups
    # shellcheck disable=SC1091
    source "$JAILBOX_DIR/src/host/core/common.sh"
    # shellcheck disable=SC1091
    source "$JAILBOX_DIR/src/host/core/container-runtime.sh"
    apply_config_defaults
    PROJECT_DIR="$PROJECT"
    initialize_project_names
    EPHEMERAL_HOME="$1"
    PATH="$FIXTURE/bin:$PATH"
    "$2"
)

test_home_creation_and_generation() {
    local mode before output status

    (
        source "$JAILBOX_DIR/src/host/core/container-runtime.sh"
        VOLUME_NAME=test-home EPHEMERAL_HOME=false
        resolve_present_resources() { local -n result=$1; result=(); }
        for fault in create inspect chown; do
            : > "$FIXTURE/home-calls"
            podman() {
                printf '%s %s\n' "$1" "$2" >> "$FIXTURE/home-calls"
                case "$fault:$1 $2" in
                    'create:volume create'|'inspect:volume inspect'|'chown:unshare chown') return 42 ;;
                esac
                [[ "$1 $2" != 'volume inspect' ]] || printf '/home-volume\n'
            }
            if ensure_home_volume; then echo "Accepted home failure: $fault" >&2; exit 1; fi
            case "$fault" in
                create) [[ $(cat "$FIXTURE/home-calls") == 'volume create' ]] ;;
                inspect) if grep -q 'unshare chown' "$FIXTURE/home-calls"; then exit 1; fi ;;
            esac
        done
    )
    pass 'conditional home setup stops after failed creation or inspection'

    for mode in true false; do
        new_project
        run_home_function "$mode" ensure_home_volume >/dev/null
        if [ "$(cat "$FAKE_PODMAN_STATE/volume.$PREFIX-home")" = "jailbox.ephemeral-home=$mode" ]; then
            pass "new home labels effective $mode mode"
        else
            fail "new home labels effective $mode mode"
        fi
        before=$(actions)
        run_home_function "$mode" ensure_home_volume >/dev/null
        if [ "$before" = "$(actions)" ]; then
            pass "existing home is not recreated or relabeled"
        else
            fail "existing home is not recreated or relabeled"
        fi
    done
    new_project
    # Isolate home eligibility here; public convergence additionally validates
    # the surviving generation, networks, image and runtime structure.
    declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=true'
    declare_resource container "$PREFIX"
    if run_home_function true require_compatible_home; then
        pass "ephemeral home is eligible only with its surviving generation"
    else
        fail "ephemeral home is eligible with surviving generation"
    fi
    status=0
    output=$(run_home_function false require_compatible_home 2>&1) || status=$?
    if [ "$status" -ne 0 ] && [[ "$output" == *"jailbox stop"* ]] && [ -z "$(actions)" ]; then
        pass "ephemeral-to-persistent refuses before mutation with stop recovery"
    else
        fail "ephemeral-to-persistent recovery (got: $output)"
    fi
    status=0
    output=$(FAKE_PODMAN_INSPECT_ERROR_KIND=volume run_home_function true require_compatible_home 2>&1) || status=$?
    if [ "$status" -ne 0 ] && [ -z "$(actions)" ] && [[ "$output" == *"could not inspect"* ]]; then
        pass "up inspection failure preserves the existing generation"
    else
        fail "up inspection failure (got: $output)"
    fi
}

test_vanished_cleanup_targets() {
    local kind name command output status

    for kind in container network volume image; do
        new_project
        declare_resource container "$PREFIX"
        declare_resource network "$PREFIX-net"
        declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=true'
        declare_resource image "$PREFIX-image"
        case "$kind" in
            container) name="$PREFIX" ;;
            network) name="$PREFIX-net" ;;
            volume) name="$PREFIX-home" ;;
            image) name="$PREFIX-image" ;;
        esac
        command=stop
        [ "$kind" != image ] || command=--clean
        status=0
        output=$(FAKE_PODMAN_VANISH_NAME="$name" run_jailbox "$PROJECT" "$command") || status=$?
        if [ "$status" -eq 0 ] && ! resource_present container "$PREFIX" &&
            ! resource_present network "$PREFIX-net" && ! resource_present volume "$PREFIX-home"; then
            pass "$command completes when $kind disappears before removal"
        else
            fail "vanished $kind cleanup (got: $output)"
        fi
    done
    new_project
    declare_resource container "$PREFIX"
    declare_resource network "$PREFIX-net"
    status=0
    output=$(FAKE_PODMAN_VANISH_NAME="$PREFIX" FAKE_PODMAN_RECHECK_ERROR=1 \
        run_jailbox "$PROJECT" stop) || status=$?
    if [ "$status" -ne 0 ] && resource_present network "$PREFIX-net"; then
        pass "failed absence recheck aborts remaining cleanup"
    else
        fail "failed absence recheck (got: $output)"
    fi
    new_project
    output=$(run_jailbox "$PROJECT" stop)
    if [[ "$output" == 'No jailbox resources to stop.' ]] && [ -z "$(actions)" ]; then
        pass "empty stop reports nothing to do"
    else
        fail "empty stop message (got: $output)"
    fi
}

test_interrupted_stop_and_exact_images() {
    local output status name

    new_project
    export JAILBOX_CONFIG_DEV_IMAGE=example.invalid/dev
    declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=false'
    declare_resource network "$PREFIX-net" 'jailbox.config-digest=stale'
    output=$(run_jailbox "$PROJECT" up || true)
    if [[ "$output" == *"jailbox stop"* && "$output" != *"jailbox --clean"* ]] && [ -z "$(actions)" ]; then
        pass "network-only mismatch refuses without mutation and names stop"
    else
        fail "network-only recovery advice (got: $output)"
    fi
    run_jailbox "$PROJECT" stop >/dev/null
    output=$(run_jailbox "$PROJECT" up || true)
    if [[ "$output" == *"Using dev image"* ]] && resource_present volume "$PREFIX-home"; then
        pass "stop resolves network mismatch without deleting persistent home"
    else
        fail "network recovery preserves home (got: $output)"
    fi

    new_project
    declare_resource container "$PREFIX"
    declare_resource network "$PREFIX-net"
    declare_resource volume "$PREFIX-home" 'jailbox.ephemeral-home=true'
    status=0
    output=$(FAKE_PODMAN_REMOVE_ERROR_NAME="$PREFIX-net" run_jailbox "$PROJECT" stop) || status=$?
    if [ "$status" -ne 0 ] && ! resource_present container "$PREFIX" && resource_present volume "$PREFIX-home"; then
        pass "failed network removal reports failure and leaves home until retry"
    else
        fail "failed network removal (got: $output)"
    fi
    if [[ "$output" == *"could not remove network '$PREFIX-net'"* &&
          "$output" == *"retry the cleanup after resolving the error"* &&
          "$output" != *"jailbox --clean"* ]]; then
        pass "failed stop identifies the blocked resource and advises retry after fixing the error"
    else
        fail "failed stop recovery advice (got: $output)"
    fi
    run_jailbox "$PROJECT" stop >/dev/null
    if ! resource_present network "$PREFIX-net" && ! resource_present volume "$PREFIX-home"; then
        pass "stop without containers completes interrupted cleanup"
    else
        fail "stop without containers completes interrupted cleanup"
    fi

    for name in "$PREFIX-dev" "$PREFIX-image" "$PREFIX-proxy" external-dev other-project-dev; do
        declare_resource image "$name"
    done
    output=$(JAILBOX_CONFIG_DEV_IMAGE=external-dev run_jailbox "$PROJECT" --clean)
    if ! resource_present image "$PREFIX-dev" && ! resource_present image "$PREFIX-image" &&
        ! resource_present image "$PREFIX-proxy" && resource_present image external-dev &&
        resource_present image other-project-dev && [[ "$output" == *"permanently deletes"* ]]; then
        pass "clean removes only exact derived image names and warns"
    else
        fail "clean image scope (got: $output)"
    fi
}

echo "lifecycle tests"
echo ""

test_stop_cleans_orphaned_ssh() {
    local config status output
    for config in missing malformed; do
        new_project
        if [ "$config" = missing ]; then
            rm "$PROJECT/jailbox.conf"
        else
            printf 'invalid configuration\n' > "$PROJECT/jailbox.conf"
        fi
        mkdir -p "$STATE_DIR/ssh-generation/server" "$STATE_DIR/.ssh-generation.interrupted"
        printf 'private\n' > "$STATE_DIR/ssh-generation/key"
        printf 'keep\n' > "$STATE_DIR/gitconfig"
        declare_resource container "$PREFIX"
        status=0
        output=$(FAKE_PODMAN_REMOVE_ERROR_NAME="$PREFIX" run_jailbox "$PROJECT" stop) || status=$?
        if [ "$status" -ne 0 ] && [ -f "$STATE_DIR/ssh-generation/key" ]; then
            pass "failed container removal preserves SSH with $config config"
        else
            fail "failed container removal preserves SSH (got: $output)"
        fi
        rm "$FAKE_PODMAN_STATE/container.$PREFIX"
        output=$(run_jailbox "$PROJECT" stop)
        if [[ "$output" == *'Removed orphaned SSH credentials'* ]]; then
            pass "orphan cleanup with $config config is reported"
        else
            fail "orphan cleanup report (got: $output)"
        fi
        run_jailbox "$PROJECT" stop >/dev/null
        if [ ! -e "$STATE_DIR/ssh-generation" ] && [ ! -e "$STATE_DIR/.ssh-generation.interrupted" ] &&
            [ "$(cat "$STATE_DIR/gitconfig")" = keep ]; then
            pass "repeated stop cleans orphaned SSH with $config config and no containers"
        else
            fail "orphan cleanup with $config config"
        fi
    done
}

test_stop_cleans_orphaned_ssh
test_stop_removes_both_project_containers
test_stop_is_idempotent_and_partial_safe
test_stop_removes_any_occupant_of_the_derived_names
test_lifecycle_fails_closed_on_exists_errors
test_stop_ignores_configuration
test_stop_requires_podman_only
test_clean_removes_every_derived_target
test_clean_removes_foreign_targets_of_any_type
test_clean_leaves_undeclared_names_alone
test_identity_requires_a_sha256_tool
test_identity_is_stable_across_path_spellings
test_both_sha256_tools_produce_the_same_identity
test_launch_rejects_legacy_containers
test_configuration_precedes_convergence
test_launch_reports_missing_podman_first
test_cksum_is_required_only_by_launch
test_uninstall_needs_no_podman_or_hash_tool
test_stop_documented_in_help
test_up_documented_in_help
test_up_ignores_editor_environment_override
test_launch_runs_without_replace
test_home_retention_and_inspection
test_home_recovery
test_home_creation_and_generation
test_interrupted_stop_and_exact_images
test_vanished_cleanup_targets

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "lifecycle tests: $PASSED passed"
else
    echo "lifecycle tests: $PASSED passed, $FAILED failed"
    exit 1
fi
