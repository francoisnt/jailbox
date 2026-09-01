#!/bin/bash
# Ownership-safe lifecycle: `stop`, `--clean`, and the launch absence check.
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
# <kind>.<name> and holds the jailbox.project label, empty for an unlabeled
# resource. Removals delete the file, so surviving files are the assertion.
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

# Declare a resource in the fake Podman state: kind, name suffix, owner label.
declare_resource() {
    printf '%s\n' "$3" > "$FAKE_PODMAN_STATE/$1.$2"
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

test_stop_removes_owned_containers_only() {
    local project output

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX" "$project"
    declare_resource container "$PREFIX-proxy" "$project"
    declare_resource volume "$PREFIX-home" "$project"
    declare_resource network "$PREFIX-net" "$project"
    mkdir -p "$STATE_DIR"
    printf 'key\n' > "$STATE_DIR/key"

    if output=$(run_jailbox "$project" stop); then
        pass "stop succeeds against an owned sandbox"
    else
        fail "stop succeeds against an owned sandbox (got: $output)"
    fi
    if ! resource_present container "$PREFIX" && ! resource_present container "$PREFIX-proxy"; then
        pass "stop removes both owned containers"
    else
        fail "stop removes both owned containers"
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

    declare_resource container "$PREFIX-proxy" "$project"
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

test_stop_refuses_unowned_containers() {
    local project output label

    for label in /somewhere/else ""; do
        new_project
        project="$PROJECT"
        declare_resource container "$PREFIX" "$project"
        declare_resource container "$PREFIX-proxy" "$label"

        output=$(run_jailbox "$project" stop || true)
        case "$output" in
            *"does not own"*"$PREFIX-proxy"*"Podman"*)
                pass "stop refuses a container labelled '$label' and names it"
                ;;
            *)
                fail "stop refuses a container labelled '$label' and names it (got: $output)"
                ;;
        esac
        if resource_present container "$PREFIX" && [ -z "$(actions)" ]; then
            pass "refused stop removed nothing, including the owned container"
        else
            fail "refused stop removed nothing, including the owned container (actions: $(actions))"
        fi
    done
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
    declare_resource container "$PREFIX" "$project"
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

test_clean_removes_every_owned_target() {
    local project output name

    new_project
    project="$PROJECT"
    declare_resource container "$PREFIX" "$project"
    declare_resource container "$PREFIX-proxy" "$project"
    declare_resource volume "$PREFIX-home" "$project"
    for name in net net-internal net-external; do
        declare_resource network "$PREFIX-$name" "$project"
    done
    mkdir -p "$STATE_DIR"
    printf 'key\n' > "$STATE_DIR/key"

    if output=$(run_jailbox "$project" --clean); then
        pass "--clean succeeds against a fully owned project"
    else
        fail "--clean succeeds against a fully owned project (got: $output)"
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

test_clean_refuses_unowned_targets_of_any_type() {
    local project output kind name

    for kind in volume network; do
        new_project
        project="$PROJECT"
        case "$kind" in
            volume) name="$PREFIX-home" ;;
            network) name="$PREFIX-net-external" ;;
        esac

        declare_resource container "$PREFIX" "$project"
        declare_resource volume "$PREFIX-home" "$project"
        declare_resource network "$PREFIX-net-external" "$project"
        declare_resource "$kind" "$name" /somewhere/else
        mkdir -p "$STATE_DIR"
        printf 'key\n' > "$STATE_DIR/key"

        output=$(run_jailbox "$project" --clean || true)
        case "$output" in
            *"does not own"*"$kind"*"$name"*"Podman"*)
                pass "--clean refuses a foreign $kind and names it"
                ;;
            *)
                fail "--clean refuses a foreign $kind and names it (got: $output)"
                ;;
        esac
        if [ -z "$(actions)" ] && resource_present container "$PREFIX" && [ -f "$STATE_DIR/key" ]; then
            pass "a foreign $kind prevents all resource and SSH-state removal"
        else
            fail "a foreign $kind prevents all resource and SSH-state removal (actions: $(actions))"
        fi
    done
}

test_launch_requires_absent_sandbox() {
    local project output name command

    for command in "" up; do
        for name in "" -proxy; do
            new_project
            project="$PROJECT"
            declare_resource container "$PREFIX$name" "$project"
            output=$(run_jailbox "$project" $command || true)
            case "$output" in
                *"jailbox stop"*)
                    pass "launch names jailbox stop for an owned ${name:-development} container"
                    ;;
                *)
                    fail "launch names jailbox stop for an owned ${name:-development} container (got: $output)"
                    ;;
            esac
            if resource_present container "$PREFIX$name" && [ -z "$(actions)" ]; then
                pass "the owned ${name:-development} container is left untouched"
            else
                fail "the owned ${name:-development} container is left untouched"
            fi

            new_project
            project="$PROJECT"
            declare_resource container "$PREFIX$name" /somewhere/else
            output=$(run_jailbox "$project" $command || true)
            case "$output" in
                *"does not own"*"Podman"*)
                    case "$output" in
                        *"jailbox stop"*)
                            fail "a foreign ${name:-development} collision must not name jailbox stop"
                            ;;
                        *)
                            pass "a foreign ${name:-development} collision names manual Podman removal"
                            ;;
                    esac
                    ;;
                *)
                    fail "a foreign ${name:-development} collision names manual Podman removal (got: $output)"
                    ;;
            esac
            if resource_present container "$PREFIX$name" && [ -z "$(actions)" ]; then
                pass "the foreign ${name:-development} container is left untouched"
            else
                fail "the foreign ${name:-development} container is left untouched"
            fi
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
        declare_resource container "$PREFIX" "$project"

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

test_stop_removes_owned_containers_only
test_stop_is_idempotent_and_partial_safe
test_stop_refuses_unowned_containers
test_lifecycle_fails_closed_on_exists_errors
test_stop_ignores_configuration
test_stop_requires_podman_only
test_clean_removes_every_owned_target
test_clean_refuses_unowned_targets_of_any_type
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
