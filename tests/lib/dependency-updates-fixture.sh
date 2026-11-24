#!/bin/bash
# Fixture repositories for the dependency-update and release-check suites.
# Callers set ROOT and tmp before sourcing; every scenario builds its own
# repository, so scenarios do not depend on one another.
: "${ROOT:?}" "${tmp:?}"

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Require LINE in FILE, showing the file when it is missing.
expect_line() { grep -Fxq -- "$2" "$1" || { cat "$1" >&2; fail "missing line: $2"; }; }
git_as() { git -c user.name='Fixture' -c user.email='fixture@example.invalid' "$@"; }
unchanged() { [[ -z $(git -C "$1" status --porcelain) ]] || fail "unexpected changes in $1"; }

# Serve upstream lookups from fixtures: the newest versions are VS Code 1.1.0,
# VSCodium 1.0.2, Debian 13, Alpine 3.25, Fedora 45, and Go 1.28.
mkdir "$tmp/bin"
cp "$ROOT/tests/fixtures/dependency-updates-curl.sh" "$tmp/bin/curl"
cp "$ROOT/tests/fixtures/dependency-updates-gh.sh" "$tmp/bin/gh"
chmod 755 "$tmp/bin/curl" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
printf '[{"version":"go1.28.2","stable":true},{"version":"go1.27.9","stable":true}]\n' > "$tmp/go.json"
export GO_RELEASE_LISTING=$tmp/go.json

# The VSCodium 1.0.2 package, whose build commit is CODIUM_BUILD_COMMIT.
CODIUM_BUILD_COMMIT=$(printf 'e%.0s' {1..40})
mkdir -p "$tmp/archive/resources/app"
printf '{"commit": "%s"}\n' "$CODIUM_BUILD_COMMIT" > "$tmp/archive/resources/app/product.json"
tar -czf "$tmp/codium.tar.gz" -C "$tmp/archive" .
export CODIUM_ARCHIVE=$tmp/codium.tar.gz

# Create DIR: a repository on master with the pins, the files generated from
# them, and the scripts under test, all committed.
make_repo() {
    local dir=$1
    mkdir -p "$dir/scripts/lib" "$dir/docs" "$dir/src/container/tinyproxy" "$dir/src/host/frontend" "$dir/tests/ci"
    cp "$ROOT"/scripts/{apply-updates,gen-tested-matrix,go-series,go-version,plan-updates,plan-release-check,record-compatibility,report-release-check,resolve-codium-commit,resolve-updates}.sh \
        "$dir/scripts/"
    cp "$ROOT"/scripts/lib/{dependency_updates.py,compatibility_history.py,base-images.sh,compatibility-history.sh} \
        "$dir/scripts/lib/"
    cat > "$dir/versions.env" <<'PINS'
CODIUM_VERSION="1.0.1"
CODIUM_COMMIT="cccccccccccccccccccccccccccccccccccccccc"   # kept comment
CODE_VERSION="1.0.0"
REMOTE_SSH_VERSION="0.1.0"
OPEN_REMOTE_SSH_VERSION="0.2.0"
BASE_IMAGE_DEBIAN="debian:12"
BASE_IMAGE_ALPINE="alpine:3.24"
BASE_IMAGE_FEDORA="fedora:41"
PINS
    printf 'module example\n\ngo 1.27\n' > "$dir/src/go.mod"
    printf 'FROM debian:trixie\nCOPY --from=docker.io/library/golang:1.27-trixie /usr/local/go /usr/local/go\n' \
        > "$dir/Containerfile"
    printf 'FROM alpine:3.24\n' > "$dir/src/container/tinyproxy/Containerfile"
    printf '# Template\nFROM docker.io/library/debian:12\nRUN true\n' > "$dir/src/host/frontend/Containerfile.template"
    printf '%s\n' '<!-- BEGIN GENERATED: tested-matrix -->' '<!-- END GENERATED: tested-matrix -->' \
        > "$dir/docs/development.md"
    bash "$dir/scripts/gen-tested-matrix.sh" --write
    git -C "$dir" init -q -b master
    git -C "$dir" add .
    git_as -C "$dir" commit -qm fixture
}
