#!/bin/bash
# Exact-name lifecycle: `stop`, `--clean`, the launch absence check, and the
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
cat > "$FIXTURE/bin/podman" <<'EOF_PODMAN'
#!/bin/sh
state="$FAKE_PODMAN_STATE"

resource_file() {
    printf '%s/%s.%s\n' "$state" "$1" "$2"
}

case "$1 $2" in
    "container exists"|"volume exists"|"network exists")
        [ "${FAKE_PODMAN_EXISTS_ERROR_KIND:-}" != "$1" ] || exit 125
        [ -f "$(resource_file "$1" "$3")" ]
        ;;
    "container inspect"|"volume inspect"|"network inspect")
        file=$(resource_file "$1" "$3")
        [ -f "$file" ] || exit 1
        cat "$file"
        ;;
    "volume rm"|"network rm")
        file=$(resource_file "$1" "$3")
        [ -f "$file" ] || exit 1
        printf '%s rm %s\n' "$1" "$3" >> "$state/actions"
        rm -f "$file"
        ;;
    *)
        case "$1" in
            stop)
                [ -f "$(resource_file container "$2")" ] || exit 1
                printf 'container stop %s\n' "$2" >> "$state/actions"
                ;;
            rm)
                file=$(resource_file container "$2")
                [ -f "$file" ] || exit 1
                printf 'container rm %s\n' "$2" >> "$state/actions"
                rm -f "$file"
                ;;
            *) exit 1 ;;
        esac
        ;;
esac
EOF_PODMAN
chmod +x "$FIXTURE/bin/podman"

# Sets PROJECT, PREFIX, STATE_DIR, and FAKE_PODMAN_STATE for the caller, so it
# must not run in a subshell.
new_project() {
    PROJECT=$(mktemp -d "$FIXTURE/project.XXXXXX")
    printf "READONLY_PATHS=\n" > "$PROJECT/jailbox.conf"
    FAKE_PODMAN_STATE="$PROJECT/.podman-state"
    mkdir -p "$FAKE_PODMAN_STATE"
    export FAKE_PODMAN_STATE
    PREFIX=$(source "$JAILBOX_DIR/host/project-id.sh" && jailbox_resource_prefix_for_path "$PROJECT")
    STATE_DIR="$FIXTURE/xdg-state/jailbox/projects/$(source "$JAILBOX_DIR/host/project-id.sh" && jailbox_project_hash_for_path "$PROJECT")"
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
            "$JAILBOX_DIR/jailbox" "$@"
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
    if resource_present volume "$PREFIX-home" && resource_present network "$PREFIX-net"; then
        pass "stop preserves the home volume and project network"
    else
        fail "stop preserves the home volume and project network"
    fi
    if [ -f "$STATE_DIR/key" ]; then
        pass "stop preserves the project state directory"
    else
        fail "stop preserves the project state directory"
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

    for kind in container volume network; do
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

    if output=$(run_jailbox "$project" --config missing.conf stop); then
        pass "stop ignores --config naming a missing file"
    else
        fail "stop ignores --config naming a missing file (got: $output)"
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
        "$JAILBOX_DIR/jailbox" stop) 2>&1 || true)
    if ! resource_present container "$PREFIX"; then
        pass "stop succeeds without SSH tooling, realpath, cksum, or an editor"
    else
        fail "stop succeeds without SSH tooling, realpath, cksum, or an editor (got: $output)"
    fi

    rm "$restricted/podman"
    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/jailbox" stop) 2>&1 || true)
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

# The absence guard makes no ownership distinction: any container holding a
# derived name blocks launch with the same stop guidance, because stop is what
# clears that name. Compatibility of a resource jailbox may reuse is the
# digest gate's separate concern, and it never runs on a present container.
test_launch_requires_absent_sandbox() {
    local project output name command labels description

    for command in "" up; do
        for name in "" -proxy; do
            for description in "this project's label" "a foreign project label" "no labels at all"; do
                new_project
                project="$PROJECT"
                case "$description" in
                    "this project's label") labels="jailbox.project=$project" ;;
                    "a foreign project label") labels="jailbox.project=/somewhere/else" ;;
                    *) labels="" ;;
                esac
                declare_resource container "$PREFIX$name" "$labels"
                output=$(run_jailbox "$project" $command || true)
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
    done
}

# An uninitialized project with a live sandbox has two blockers. The stop
# precondition is reported first because launch must not mutate anything while
# a sandbox holds the project mounted writable.
test_stop_precondition_precedes_initialization() {
    local project output command

    for command in "" up; do
        new_project
        project="$PROJECT"
        rm "$project/jailbox.conf"
        declare_resource container "$PREFIX"

        output=$(run_jailbox "$project" $command || true)
        case "$output" in
            *"jailbox stop"*) pass "launch reports the stop precondition before initialization" ;;
            *) fail "launch reports the stop precondition before initialization (got: $output)" ;;
        esac
        case "$output" in
            *"jailbox init"*) fail "the initialization requirement is not reported yet" ;;
            *) pass "the initialization requirement is not reported yet" ;;
        esac

        run_jailbox "$project" stop >/dev/null
        output=$(run_jailbox "$project" $command || true)
        case "$output" in
            *"Project is not initialized"*"jailbox init"*)
                pass "the next launch after stopping reports the initialization requirement"
                ;;
            *)
                fail "the next launch after stopping reports the initialization requirement (got: $output)"
                ;;
        esac
    done
}

test_launch_reports_missing_podman_first() {
    local project restricted tool resolved output

    restricted="$FIXTURE/no-podman-bin"
    mkdir -p "$restricted"
    # Link only the tools needed to reach the launch dependency check. Adding
    # a system directory to PATH is not safe here: Podman commonly lives
    # beside sed and the test would accidentally expose the command it is
    # meant to exclude.
    for tool in bash dirname basename tr cut sha256sum shasum; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$resolved" "$restricted/$tool"
    done
    new_project
    project="$PROJECT"
    output=$( (cd "$project" && PATH="$restricted" \
        XDG_STATE_HOME="$FIXTURE/xdg-state" "$JAILBOX_DIR/jailbox") 2>&1 || true)
    case "$output" in
        *"required command not found: podman"*)
            pass "bare launch reports missing podman before probing container names"
            ;;
        *)
            fail "bare launch reports missing podman before probing container names (got: $output)"
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
    for command in stop doctor ssh-config --clean; do
        if output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
            "$JAILBOX_DIR/jailbox" "$command") 2>&1); then
            pass "$command succeeds without cksum"
        else
            fail "$command succeeds without cksum (got: $output)"
        fi
    done

    # In a source checkout --uninstall stops at the install-copy check; reaching
    # that message proves it required neither Podman nor a hash tool.
    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/jailbox" --uninstall) 2>&1 || true)
    case "$output" in
        *"not an installed copy"*) pass "--uninstall reaches the installer without cksum" ;;
        *) fail "--uninstall reaches the installer without cksum (got: $output)" ;;
    esac

    output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
        "$JAILBOX_DIR/jailbox") 2>&1 || true)
    case "$output" in
        *"required command not found: cksum"*)
            pass "bare launch still requires cksum before building the wrapper image"
            ;;
        *)
            fail "bare launch still requires cksum before building the wrapper image (got: $output)"
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
        "$JAILBOX_DIR/jailbox" --uninstall) 2>&1 || true)
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
        *"Usage:"*"[init|up|stop|doctor|"*) pass "stop appears in the literal usage synopsis" ;;
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
        *"Usage:"*"[init|up|stop|doctor|"*) pass "up appears in the literal usage synopsis" ;;
        *) fail "up appears in the literal usage synopsis (got: $output)" ;;
    esac
    case "$output" in
        *"up"*"Launch the sandbox without opening an editor"*)
            pass "up appears in the generated options block"
            ;;
        *) fail "up appears in the generated options block (got: $output)" ;;
    esac
}

test_up_ignores_editor_environment_override() {
    local project output

    new_project
    project="$PROJECT"
    printf 'DEV_IMAGE=example.invalid/dev\n' > "$project/jailbox.conf"
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

    for command in stop --clean doctor ssh-config up ""; do
        new_project
        project="$PROJECT"
        declare_resource container "$PREFIX"
        mkdir -p "$STATE_DIR"
        printf 'key\n' > "$STATE_DIR/key"

        output=$( (cd "$project" && PATH="$restricted" XDG_STATE_HOME="$FIXTURE/xdg-state" \
            "$JAILBOX_DIR/jailbox" $command) 2>&1 || true)
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
                "$JAILBOX_DIR/jailbox" stop
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
            "$JAILBOX_DIR/jailbox" stop) 2>&1 || true)
        if ! resource_present container "$PREFIX"; then
            pass "$tool alone derives the shared project identity"
        else
            fail "$tool alone derives the shared project identity (got: $output)"
        fi
    done
}

test_launch_runs_without_replace() {
    if grep -Fq -- '--replace' "$JAILBOX_DIR/host/container-runtime.sh" ||
        grep -Fq -- '--replace' "$JAILBOX_DIR/host/network.sh"; then
        fail "development and proxy runs do not use --replace"
    else
        pass "development and proxy runs do not use --replace"
    fi
    if grep -Fq 'Replacing existing' "$JAILBOX_DIR/host/container-runtime.sh" ||
        grep -Fq 'Replacing existing' "$JAILBOX_DIR/host/network.sh"; then
        fail "dead replacement notices are removed"
    else
        pass "dead replacement notices are removed"
    fi
}

echo "lifecycle tests"
echo ""

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
test_launch_requires_absent_sandbox
test_stop_precondition_precedes_initialization
test_launch_reports_missing_podman_first
test_cksum_is_required_only_by_launch
test_uninstall_needs_no_podman_or_hash_tool
test_stop_documented_in_help
test_up_documented_in_help
test_up_ignores_editor_environment_override
test_launch_runs_without_replace

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "lifecycle tests: $PASSED passed"
else
    echo "lifecycle tests: $PASSED passed, $FAILED failed"
    exit 1
fi
