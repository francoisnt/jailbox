#!/bin/bash
# Local dependency updates: applying them, looking up the newest versions, and
# planning. Each scenario builds its own fixture repository.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=tests/lib/dependency-updates-fixture.sh
source "$ROOT/tests/lib/dependency-updates-fixture.sh"

python3 "$ROOT/tests/lib/test-dependency-updates.py" 2> "$tmp/rules.log" || { cat "$tmp/rules.log" >&2; exit 1; }

apply() { bash "$repo/scripts/apply-updates.sh" "$@" > "$tmp/log" 2>&1; }
expect_apply_failure() {
    local message=$1
    shift
    if apply "$@"; then fail "apply-updates $* succeeded"; fi
    grep -Fq -- "$message" "$tmp/log" || { cat "$tmp/log" >&2; fail "missing: $message"; }
}

test_apply_writes_pins_and_generated_files() {
    repo=$tmp/apply
    make_repo "$repo"
    # shellcheck disable=SC2016 # The command substitution must stay literal.
    for bad in '' 'debian' 'BASE_IMAGE_DEBIAN=debian:13;touch x' 'BASE_IMAGE_DEBIAN=ubuntu:24' \
        'BASE_IMAGE_ALPINE=alpine:3' 'CODIUM_VERSION=2.0.0' 'GO_SERIES=1.28.1' 'CODE_VERSION=$(id)'; do
        expect_apply_failure 'Error' "$bad"
    done
    unchanged "$repo"
    local commit
    commit=$(printf 'd%.0s' {1..40})
    apply BASE_IMAGE_DEBIAN=debian:13 BASE_IMAGE_ALPINE=alpine:3.25 "CODIUM_VERSION=1.0.2 CODIUM_COMMIT=$commit" \
        CODE_VERSION=1.1.0 GO_SERIES=1.28 || { cat "$tmp/log" >&2; fail 'apply-updates failed'; }
    grep -Fxq 'BASE_IMAGE_DEBIAN="debian:13"' "$repo/versions.env"
    grep -Fxq "CODIUM_COMMIT=\"$commit\"   # kept comment" "$repo/versions.env"
    grep -Fxq 'FROM alpine:3.25' "$repo/src/container/tinyproxy/Containerfile"
    grep -Fxq 'FROM docker.io/library/debian:13' "$repo/src/host/frontend/Containerfile.template"
    grep -Fxq 'go 1.28' "$repo/src/go.mod"
    grep -Fq 'golang:1.28-trixie ' "$repo/Containerfile"
    grep -Fxq '| Debian 13 | ✅ | ✅ |' "$repo/docs/development.md"
    bash "$repo/scripts/gen-tested-matrix.sh" --check
}

test_apply_refuses_existing_edits() {
    repo=$tmp/edits
    make_repo "$repo"
    # Edits to the pins or generated files are refused and kept, staged or not.
    local file
    for file in versions.env docs/development.md src/go.mod; do
        printf '# edit\n' >> "$repo/$file"
        expect_apply_failure 'commit or stash your staged or unstaged changes' BASE_IMAGE_DEBIAN=debian:13
        grep -Fxq '# edit' "$repo/$file"
        git -C "$repo" checkout -q -- "$file"
    done
    printf '# staged\n' >> "$repo/versions.env"
    git -C "$repo" add versions.env
    git -C "$repo" show HEAD:versions.env > "$repo/versions.env"
    expect_apply_failure 'commit or stash' BASE_IMAGE_DEBIAN=debian:13
    git -C "$repo" show :versions.env | grep -Fxq '# staged'
}

test_go_series_update_keeps_newer_toolchains() {
    repo=$tmp/toolchain
    make_repo "$repo"
    # A Go series update drops an older toolchain and keeps other settings.
    local toolchain
    for toolchain in go1.27.3 go1.28.1 go1.29.0 default; do
        printf 'module example\n\ngo 1.27\n\ntoolchain %s\n' "$toolchain" > "$repo/src/go.mod"
        git_as -C "$repo" commit -qam "toolchain $toolchain"
        apply GO_SERIES=1.28 || { cat "$tmp/log" >&2; fail "apply-updates failed with toolchain $toolchain"; }
        grep -Fxq 'go 1.28' "$repo/src/go.mod"
        if [[ $toolchain == go1.27.3 ]]; then
            if grep -q '^toolchain' "$repo/src/go.mod"; then fail 'an older toolchain line was kept'; fi
        else
            grep -Fxq "toolchain $toolchain" "$repo/src/go.mod" || fail "toolchain $toolchain was not kept"
        fi
        git -C "$repo" reset -q --hard HEAD^
    done
}

test_failure_undoes_every_change() {
    repo=$tmp/failure
    make_repo "$repo"
    printf 'FROM debian:trixie\n' > "$repo/Containerfile"
    git_as -C "$repo" commit -qam 'Containerfile without the Go image'
    expect_apply_failure 'the changes were undone' BASE_IMAGE_DEBIAN=debian:13 GO_SERIES=1.28
    unchanged "$repo"
    git -C "$repo" reset -q --hard HEAD^
    printf '# Template\nRUN true\n' > "$repo/src/host/frontend/Containerfile.template"
    git_as -C "$repo" commit -qam 'template without FROM'
    expect_apply_failure 'has no FROM line to update' BASE_IMAGE_DEBIAN=debian:13
    unchanged "$repo"
}

test_interruption_undoes_written_pins() {
    repo=$tmp/interrupt
    make_repo "$repo"
    # A background job ignores SIGINT, so this covers the other catchable signals.
    mv "$repo/scripts/gen-tested-matrix.sh" "$repo/scripts/gen-tested-matrix-real.sh"
    cat > "$repo/scripts/gen-tested-matrix.sh" <<'GENERATOR'
#!/bin/bash
# Hold --write until the test has interrupted the update.
if [[ ${1-} == --write ]]; then
    touch "$GENERATOR_STARTED"
    while [[ ! -e "$GENERATOR_RELEASE" ]]; do sleep 0.1; done
fi
exec bash "$(dirname "$0")/gen-tested-matrix-real.sh" "$@"
GENERATOR
    git -C "$repo" add scripts
    git_as -C "$repo" commit -qm 'generator that waits'
    local signal pid status
    for signal in TERM HUP; do
        rm -f "$tmp/started" "$tmp/release"
        GENERATOR_STARTED=$tmp/started GENERATOR_RELEASE=$tmp/release \
            bash "$repo/scripts/apply-updates.sh" BASE_IMAGE_DEBIAN=debian:13 > "$tmp/log" 2>&1 &
        pid=$!
        for _ in {1..300}; do [[ -e "$tmp/started" ]] && break; sleep 0.1; done
        [[ -e "$tmp/started" ]] || { touch "$tmp/release"; fail 'regeneration did not start'; }
        grep -Fxq 'BASE_IMAGE_DEBIAN="debian:13"' "$repo/versions.env" || fail 'the pins were not written first'
        kill -s "$signal" "$pid"
        touch "$tmp/release"
        status=0
        wait "$pid" || status=$?
        [[ $status -ne 0 ]] || fail "apply-updates succeeded after SIG$signal"
        grep -Fq 'the changes were undone' "$tmp/log" || { cat "$tmp/log" >&2; fail "SIG$signal left changes"; }
        unchanged "$repo"
    done
}

test_generator_names_stale_copies() {
    repo=$tmp/stale
    make_repo "$repo"
    sed -i.bak 's/^BASE_IMAGE_ALPINE=.*/BASE_IMAGE_ALPINE="alpine:3.25"/' "$repo/versions.env" && rm "$repo/versions.env.bak"
    if bash "$repo/scripts/gen-tested-matrix.sh" --check > "$tmp/log" 2>&1; then fail 'stale generated files passed'; fi
    grep -Fq 'src/container/tinyproxy/Containerfile FROM (alpine:3.24)' "$tmp/log"
}

test_version_lookups() {
    repo=$tmp/lookups
    make_repo "$repo"
    GO_RELEASE_LISTING='' GO_LISTING_FIXTURE="$tmp/go.json" GO_LOOKUP_LOG="$tmp/go-lookups" \
        bash "$repo/scripts/resolve-updates.sh" > "$tmp/newest" 2> "$tmp/log" ||
        { cat "$tmp/log" >&2; fail 'resolve-updates failed'; }
    [[ $(wc -l < "$tmp/go-lookups") -eq 1 ]] || fail 'Go release list was not fetched exactly once'
    local line failure status
    for line in CODIUM_VERSION=1.0.2 CODE_VERSION=1.1.0 REMOTE_SSH_VERSION=0.1.0 OPEN_REMOTE_SSH_VERSION=0.2.0 \
        BASE_IMAGE_DEBIAN=debian:13 BASE_IMAGE_ALPINE=alpine:3.25 BASE_IMAGE_FEDORA=fedora:45 GO_SERIES=1.28; do
        grep -Fxq "$line" "$tmp/newest" || fail "missing $line"
    done
    for failure in 'ALPINE_MANIFEST=ambiguous' 'FAIL_URL=open-vsx' 'GO_RELEASE_LISTING=/nonexistent'; do
        if env "$failure" bash "$repo/scripts/resolve-updates.sh" > "$tmp/newest" 2>/dev/null; then
            fail "lookup passed with $failure"
        fi
        [[ ! -s "$tmp/newest" ]] || fail "a failed lookup printed partial versions with $failure"
    done
    # Unsupported is not a lookup failure: go-version.sh keeps them apart.
    printf '[{"version":"go1.29.0","stable":true},{"version":"go1.28.2","stable":true}]\n' > "$tmp/go-old.json"
    status=0
    GO_RELEASE_LISTING=$tmp/go-old.json bash "$repo/scripts/go-version.sh" > /dev/null 2>&1 || status=$?
    [[ $status -eq 3 ]] || fail "unsupported Go exited $status"
    status=0
    GO_RELEASE_LISTING=/nonexistent bash "$repo/scripts/go-version.sh" > /dev/null 2>&1 || status=$?
    [[ $status -eq 1 ]] || fail "failed Go lookup exited $status"
}

test_codium_build_commit() {
    repo=$tmp/codium
    make_repo "$repo"
    [[ $(bash "$repo/scripts/resolve-codium-commit.sh" 1.0.2) == "$CODIUM_BUILD_COMMIT" ]] || fail 'wrong VSCodium commit'
    mkdir -p "$tmp/bad-archive/resources/app"
    printf '{"commit": "unknown"}\n' > "$tmp/bad-archive/resources/app/product.json"
    tar -czf "$tmp/bad.tar.gz" -C "$tmp/bad-archive" .
    if CODIUM_ARCHIVE=$tmp/bad.tar.gz bash "$repo/scripts/resolve-codium-commit.sh" 1.0.2 > /dev/null 2>&1; then
        fail 'an invalid VSCodium commit was accepted'
    fi
}

test_planner_lists_and_checks_updates() {
    repo=$tmp/planner
    make_repo "$repo"
    # The planner lists complete, separately applicable updates, and leaves
    # the checkout's files and history alone.
    local base update pairs wrong_commit
    base=$(git -C "$repo" rev-parse HEAD)
    bash "$repo/scripts/plan-updates.sh" > "$tmp/plan"
    cat > "$tmp/expected" <<UPDATES
CODE_VERSION=1.1.0
CODIUM_VERSION=1.0.2 CODIUM_COMMIT=$CODIUM_BUILD_COMMIT
BASE_IMAGE_DEBIAN=debian:13
BASE_IMAGE_ALPINE=alpine:3.25
BASE_IMAGE_FEDORA=fedora:45
GO_SERIES=1.28
UPDATES
    cmp "$tmp/expected" "$tmp/plan"
    unchanged "$repo"
    [[ $(git -C "$repo" rev-parse HEAD) == "$base" ]]
    if CODIUM_ARCHIVE=/nonexistent bash "$repo/scripts/plan-updates.sh" --check > "$tmp/plan" 2> "$tmp/log"; then
        fail 'release check accepted outdated pins'
    fi
    expect_line "$tmp/log" 'Release requires updated dependency pins. Available updates:'
    while IFS= read -r update; do
        expect_line "$tmp/log" "${update%% *}"
    done < "$tmp/expected"
    if FAIL_URL=open-vsx bash "$repo/scripts/plan-updates.sh" --check > "$tmp/plan" 2> "$tmp/log"; then
        fail 'release check passed after a failed lookup'
    fi
    expect_line "$tmp/log" 'Could not verify that all dependency pins are current.'
    if CODIUM_ARCHIVE=/nonexistent bash "$repo/scripts/plan-updates.sh" > "$tmp/plan" 2> "$tmp/log"; then
        fail 'planning passed without the VSCodium build commit'
    fi
    [[ ! -s "$tmp/plan" ]] || fail 'a failed lookup printed incomplete updates'
    unchanged "$repo"

    # Applying every listed update makes the pins current.
    while IFS= read -r update; do
        read -r -a pairs <<< "$update"
        bash "$repo/scripts/apply-updates.sh" "${pairs[@]}"
        git_as -C "$repo" commit -qam "Apply $update"
    done < "$tmp/expected"
    CODIUM_ARCHIVE=/nonexistent bash "$repo/scripts/plan-updates.sh" > "$tmp/plan"
    [[ ! -s "$tmp/plan" ]] || fail 'a current pin was proposed as an update'
    bash "$repo/scripts/plan-updates.sh" --check
    if CODIUM_ARCHIVE=/nonexistent bash "$repo/scripts/plan-updates.sh" --check > "$tmp/plan" 2> "$tmp/log"; then
        fail 'release check passed without verifying the VSCodium build commit'
    fi
    expect_line "$tmp/log" 'Could not verify the VSCodium build commit for 1.0.2.'
    for wrong_commit in invalid-commit "$CODIUM_BUILD_COMMIT GO_SERIES=1.28" "$(printf 'd%.0s' {1..40})"; do
        sed -i.bak "s/$CODIUM_BUILD_COMMIT/$wrong_commit/" "$repo/versions.env" && rm "$repo/versions.env.bak"
        if bash "$repo/scripts/plan-updates.sh" --check > "$tmp/plan" 2> "$tmp/log"; then
            fail "release check accepted CODIUM_COMMIT=$wrong_commit"
        fi
        grep -Fq 'CODIUM_COMMIT' "$tmp/log" || fail 'release check did not name the mismatched pin'
        git -C "$repo" checkout -q -- versions.env
    done
    unchanged "$repo"
}

test_apply_writes_pins_and_generated_files
test_apply_refuses_existing_edits
test_go_series_update_keeps_newer_toolchains
test_failure_undoes_every_change
test_interruption_undoes_written_pins
test_generator_names_stale_copies
test_version_lookups
test_codium_build_commit
test_planner_lists_and_checks_updates
printf 'PASS: local dependency updates\n'
