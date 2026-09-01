#!/bin/bash
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

mkdir "$FIXTURE/bin"
cat > "$FIXTURE/bin/podman" <<'EOF_PODMAN'
#!/bin/sh
if [ "$1 $2" = "container exists" ]; then
    [ "${FAKE_CONTAINER_NAME:-}" = "$3" ]
elif [ "$1 $2" = "container inspect" ]; then
    printf '%s\n' "${FAKE_CONTAINER_OWNER:-}"
else
    exit 1
fi
EOF_PODMAN
chmod +x "$FIXTURE/bin/podman"

run_jailbox() {
    PATH="$FIXTURE/bin:$PATH" "$JAILBOX_DIR/jailbox" "$@"
}

test_creation_and_no_clobber() {
    local project expected output

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    expected=$'# Additional project paths mounted read-only inside the sandbox.\nREADONLY_PATHS='
    (cd "$project" && run_jailbox init) >/dev/null
    if [ "$(cat "$project/jailbox.conf")" = "$expected" ]; then
        pass "init creates the complete minimal template"
    else
        fail "init creates the complete minimal template"
    fi
    output=$( (cd "$project" && run_jailbox init) 2>&1 || true)
    case "$output" in
        *"already exists"*) pass "init refuses to overwrite an existing file" ;;
        *) fail "init refuses to overwrite an existing file" ;;
    esac
}

test_existing_destination_types() {
    local kind project output

    for kind in directory symlink fifo; do
        project=$(mktemp -d "$FIXTURE/project.XXXXXX")
        case "$kind" in
            directory) mkdir "$project/jailbox.conf" ;;
            symlink) ln -s missing "$project/jailbox.conf" ;;
            fifo) mkfifo "$project/jailbox.conf" ;;
        esac
        output=$( (cd "$project" && run_jailbox init) 2>&1 || true)
        case "$output" in
            *"already exists"*) pass "init refuses existing $kind" ;;
            *) fail "init refuses existing $kind" ;;
        esac
    done
}

test_config_rejected_before_creation() {
    local project

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    if (cd "$project" && run_jailbox --config elsewhere init) >/dev/null 2>&1; then
        fail "--config init is rejected"
    elif [ ! -e "$project/jailbox.conf" ]; then
        pass "--config init is rejected before creation"
    else
        fail "--config init is rejected before creation"
    fi
}

test_container_collisions() {
    local project name output

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    name=$(cd "$project" && source "$JAILBOX_DIR/host/project-id.sh" && jailbox_resource_prefix_for_path "$project")
    output=$( (cd "$project" && FAKE_CONTAINER_NAME="$name" FAKE_CONTAINER_OWNER="$project" run_jailbox init) 2>&1 || true)
    case "$output" in
        *"project sandbox"*"jailbox stop"*) pass "owned container blocks init and names jailbox stop" ;;
        *) fail "owned container blocks init and names jailbox stop (got: $output)" ;;
    esac
    [ ! -e "$project/jailbox.conf" ] || fail "owned collision created no config"

    output=$( (cd "$project" && FAKE_CONTAINER_NAME="${name}-proxy" FAKE_CONTAINER_OWNER=/different run_jailbox init) 2>&1 || true)
    case "$output" in
        *"does not own"*"Podman"*) pass "foreign proxy collision blocks init" ;;
        *) fail "foreign proxy collision blocks init (got: $output)" ;;
    esac
    [ ! -e "$project/jailbox.conf" ] || fail "foreign collision created no config"
}

test_concurrent_publication() {
    local project successes leftovers

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    successes=0
    (cd "$project" && run_jailbox init) >/dev/null 2>&1 &
    first=$!
    (cd "$project" && run_jailbox init) >/dev/null 2>&1 &
    second=$!
    if wait "$first"; then
        successes=$((successes + 1))
    fi
    if wait "$second"; then
        successes=$((successes + 1))
    fi
    leftovers=$(find "$project" -maxdepth 1 -name '.jailbox.conf.tmp.*' -print)
    if [ "$successes" -eq 1 ] && [ -f "$project/jailbox.conf" ] && [ -z "$leftovers" ]; then
        pass "concurrent init publishes once without temporary files"
    else
        fail "concurrent init publishes once without temporary files"
    fi
}

# init must reach its own scoped preflight without the launch toolchain. Build a
# PATH holding only the commands project-name derivation and safe publication
# need, so a reintroduced SSH, realpath, cksum, or editor requirement fails here
# instead of surfacing as a first-run failure on a machine without them.
test_init_needs_podman_only() {
    local project restricted tool resolved forbidden excluded output

    restricted="$FIXTURE/restricted-bin"
    mkdir -p "$restricted"
    cp "$FIXTURE/bin/podman" "$restricted/podman"
    for tool in bash dirname basename tr cut sed mktemp ln rm sha256sum shasum; do
        resolved=$(command -v "$tool" 2>/dev/null) || continue
        ln -s "$resolved" "$restricted/$tool"
    done

    # The restricted PATH is exactly this one directory, so absence from it is
    # absence from the lookup path.
    excluded=1
    for forbidden in ssh ssh-keygen realpath cksum code codium; do
        [ ! -e "$restricted/$forbidden" ] || excluded=0
    done
    if [ "$excluded" -eq 1 ]; then
        pass "restricted PATH excludes the launch toolchain"
    else
        fail "restricted PATH excludes the launch toolchain"
    fi

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    output=$( (cd "$project" && PATH="$restricted" "$JAILBOX_DIR/jailbox" init) 2>&1 || true)
    if [ -f "$project/jailbox.conf" ]; then
        pass "init succeeds without SSH tooling, realpath, cksum, or an editor"
    else
        fail "init succeeds without SSH tooling, realpath, cksum, or an editor (got: $output)"
    fi

    rm "$restricted/podman"
    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    output=$( (cd "$project" && PATH="$restricted" "$JAILBOX_DIR/jailbox" init) 2>&1 || true)
    case "$output" in
        *"required command not found: podman"*) pass "init still requires podman" ;;
        *) fail "init still requires podman (got: $output)" ;;
    esac
    [ ! -e "$project/jailbox.conf" ] || fail "missing podman created no config"
}

# A failed publication must be reported as a publication error. Calling it
# "already exists" would claim a config is present when none is.
test_publication_failure_without_destination() {
    local project failing output leftovers

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    failing="$FIXTURE/failing-bin"
    mkdir -p "$failing"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$failing/ln"
    chmod +x "$failing/ln"

    output=$( (cd "$project" && PATH="$failing:$FIXTURE/bin:$PATH" "$JAILBOX_DIR/jailbox" init) 2>&1 || true)
    case "$output" in
        *"already exists"*) fail "publication failure is not reported as a lost race (got: $output)" ;;
        *"could not publish"*) pass "publication failure with no destination is reported as an error" ;;
        *) fail "publication failure with no destination is reported as an error (got: $output)" ;;
    esac

    leftovers=$(find "$project" -maxdepth 1 -name '.jailbox.conf.tmp.*' -print)
    if [ ! -e "$project/jailbox.conf" ] && [ -z "$leftovers" ]; then
        pass "failed publication leaves no config and no temporary file"
    else
        fail "failed publication leaves no config and no temporary file"
    fi
}

# ln interprets an existing destination directory as a request to create a
# link inside it. Force that race after init's initial absence check and ensure
# jailbox neither reports success nor leaves the unintended nested hard link.
test_publication_race_with_directory() {
    local project racing real_ln output leftovers

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    racing="$FIXTURE/racing-bin"
    mkdir -p "$racing"
    real_ln=$(command -v ln)
    cat > "$racing/ln" <<'EOF_LN'
#!/bin/sh
destination="$3"
mkdir "$destination" || exit 1
exec "$REAL_LN" "$@"
EOF_LN
    chmod +x "$racing/ln"

    output=$( (cd "$project" && REAL_LN="$real_ln" PATH="$racing:$FIXTURE/bin:$PATH" \
        "$JAILBOX_DIR/jailbox" init) 2>&1 || true)
    case "$output" in
        *"Created "*) fail "directory publication race is not reported as success" ;;
        *"already exists"*) pass "directory publication race is rejected" ;;
        *) fail "directory publication race is rejected (got: $output)" ;;
    esac

    leftovers=$(find "$project" -name '.jailbox.conf.tmp.*' -print)
    if [ -d "$project/jailbox.conf" ] && [ -z "$leftovers" ]; then
        pass "directory publication race leaves no temporary hard link"
    else
        fail "directory publication race leaves no temporary hard link"
    fi
}

test_generated_config_is_selected() {
    local project

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    (cd "$project" && run_jailbox init) >/dev/null

    if (
        # shellcheck disable=SC1091
        source "$JAILBOX_DIR/host/public-api.sh"
        # shellcheck disable=SC1091
        source "$JAILBOX_DIR/host/common.sh"
        PROJECT_DIR="$project"
        apply_config_defaults
        CONFIG_PATH_ARG=""
        prepare_config_selection ""
        load_project_config
        [ "$CONFIG_FILE" = "$project/jailbox.conf" ] && [ -z "${READONLY_PATHS[*]-}" ]
    ) >/dev/null 2>&1; then
        pass "bare launch selects the generated config and parses an empty policy"
    else
        fail "bare launch selects the generated config and parses an empty policy"
    fi
}

test_init_documented_in_help() {
    local project output

    project=$(mktemp -d "$FIXTURE/project.XXXXXX")
    output=$( (cd "$project" && run_jailbox --help) 2>&1 || true)
    case "$output" in
        *"Usage:"*"[init|up|stop|doctor|"*) pass "init appears in the literal usage synopsis" ;;
        *) fail "init appears in the literal usage synopsis (got: $output)" ;;
    esac
    case "$output" in
        *"init"*"Create the default project jailbox.conf"*)
            pass "init appears in the generated options block"
            ;;
        *)
            fail "init appears in the generated options block (got: $output)"
            ;;
    esac
}
test_creation_and_no_clobber
test_existing_destination_types
test_config_rejected_before_creation
test_container_collisions
test_concurrent_publication
test_init_needs_podman_only
test_publication_failure_without_destination
test_publication_race_with_directory
test_generated_config_is_selected
test_init_documented_in_help

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "init config tests: $PASSED passed"
else
    echo "init config tests: $PASSED passed, $FAILED failed"
    exit 1
fi
