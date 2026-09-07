#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/host"
cp "$ROOT/scripts/"{release,public-api-diff,select-release-request}.sh "$tmp/scripts/"
cat > "$tmp/host/public-api.sh" <<'API'
CONFIG_SCALAR_KEYS=(
    ORIGINAL
)
API
git -C "$tmp" init -q
git -C "$tmp" -c user.name=test -c user.email=test@example.invalid add scripts host
git -C "$tmp" -c user.name=test -c user.email=test@example.invalid commit -qm baseline

assert_version() {
    local expected=$1 actual
    shift
    actual=$(bash "$tmp/scripts/release.sh" --print-version "$@" < /dev/null)
    [[ "$actual" == "$expected" ]] || { echo "Expected $expected, got $actual" >&2; exit 1; }
}
reject() {
    if "$@" > "$tmp/out" 2> "$tmp/err"; then
        echo "Expected refusal: $*" >&2
        exit 1
    fi
    [[ ! -s "$tmp/out" && -s "$tmp/err" ]]
}

assert_version v0.1.0
assert_version v1.0.0 --bump major
assert_version v1.0.0 --first-major
git -C "$tmp" tag v0.8.2
assert_version v0.8.3
assert_version v0.9.0 --bump minor
assert_version v1.0.0 --bump major
assert_version v0.8.3 --bump patch
assert_version v0.8.3 --yes
reject bash "$tmp/scripts/release.sh" --print-version --bump invalid
reject bash "$tmp/scripts/release.sh" --print-version --bump
reject bash "$tmp/scripts/release.sh" --print-version --bump minor --first-major
reject bash "$tmp/scripts/release.sh" --print-version --first-major --bump major

# Additions stay patch before 1.0; removals dominate simultaneous additions.
sed '/    ORIGINAL/a\
    ADDED
' "$tmp/host/public-api.sh" > "$tmp/api"
cp "$tmp/api" "$tmp/host/public-api.sh"
assert_version v0.8.3
sed '/    ORIGINAL/d' "$tmp/api" > "$tmp/host/public-api.sh"
assert_version v0.9.0 --bump patch
assert_version v0.9.0 --bump minor

git -C "$tmp" show HEAD:host/public-api.sh > "$tmp/host/public-api.sh"
for level in patch minor major; do
    case "$level" in
        patch) expected=v0.8.3 ;;
        minor) expected=v0.9.0 ;;
        major) expected=v1.0.0 ;;
    esac
    tag="release-request-bump-$level"
    [[ "$tag" != v[0-9]*.[0-9]*.[0-9]* ]]
    actual=$(RELEASE_EVENT=push REQUEST_TAG="$tag" bash "$tmp/scripts/select-release-request.sh")
    [[ "$actual" == "$expected" ]]
    actual=$(RELEASE_EVENT=workflow_dispatch BUMP="$level" FIRST_MAJOR=false bash "$tmp/scripts/select-release-request.sh")
    [[ "$actual" == "$expected" ]]
done
for tag in release-request release-request-first-major; do
    [[ "$tag" != v[0-9]*.[0-9]*.[0-9]* ]]
    actual=$(RELEASE_EVENT=push REQUEST_TAG="$tag" bash "$tmp/scripts/select-release-request.sh")
    case "$tag" in
        release-request) [[ "$actual" == v0.8.3 ]] ;;
        *) [[ "$actual" == v1.0.0 ]] ;;
    esac
done
reject env RELEASE_EVENT=workflow_dispatch FIRST_MAJOR=true BUMP=minor bash "$tmp/scripts/select-release-request.sh"
reject env RELEASE_EVENT=workflow_dispatch FIRST_MAJOR=true BUMP=major bash "$tmp/scripts/select-release-request.sh"
reject env RELEASE_EVENT=workflow_dispatch BUMP=invalid bash "$tmp/scripts/select-release-request.sh"
reject env RELEASE_EVENT=push REQUEST_TAG=v9.9.9 bash "$tmp/scripts/select-release-request.sh"
actual=$(RELEASE_EVENT=workflow_dispatch BUMP=auto bash "$tmp/scripts/select-release-request.sh")
[[ "$actual" == v0.8.3 ]]

git -C "$tmp" tag v1.2.3
assert_version v1.2.4
assert_version v1.3.0 --bump minor
assert_version v2.0.0 --bump major
reject bash "$tmp/scripts/release.sh" --print-version --first-major
cp "$tmp/api" "$tmp/host/public-api.sh"
assert_version v1.3.0 --bump patch
sed '/    ORIGINAL/d' "$tmp/api" > "$tmp/host/public-api.sh"
assert_version v2.0.0 --bump minor

# Exercise the actual prompt and emitted dispatch arguments without pushing.
(
    # shellcheck source=scripts/release.sh
    source "$ROOT/scripts/release.sh"
    ROOT_DIR=$tmp
    git() {
        if [[ "${3:-}" == push ]]; then
            printf '%s\n' "$@" > "$tmp/push"
        else
            command git "$@"
        fi
    }
    command git -C "$tmp" show HEAD:host/public-api.sh > "$tmp/host/public-api.sh"
    select_release_version
    REQUESTED_BUMP=minor
    select_release_version
    choose_bump <<< '' > "$tmp/prompt"
    grep -Fq 'Automatic bump: patch.' "$tmp/prompt"
    grep -Fq 'Requested minimum bump: minor.' "$tmp/prompt"
    grep -Fq 'Selected version after applying the minimum: v1.3.0.' "$tmp/prompt"
    choose_bump <<< major > "$tmp/prompt"
    [[ "$SELECTED_VERSION" == v2.0.0 ]]
    confirm_release <<< y > /dev/null
    dispatch_release > /dev/null
    grep -Fxq 'HEAD:refs/tags/release-request-bump-major' "$tmp/push"
    REQUESTED_BUMP=""
    dispatch_release > /dev/null
    grep -Fxq 'HEAD:refs/tags/release-request' "$tmp/push"
    YES=true
    choose_bump < /dev/null
)
output=$(bash "$tmp/scripts/release.sh" --dry-run --bump major < /dev/null)
[[ "$output" == *'Selected version: v2.0.0'* && "$output" == *'Dry run: no release dispatched.'* ]]

# Malformed base versions must fail before selection or arithmetic, even when
# bumping would otherwise erase the malformed component.
git -C "$tmp" tag -d v0.8.2 v1.2.3 > /dev/null
for tag in v09.2.3 v9.02.3 v9.2.03; do
    git -C "$tmp" tag "$tag"
    reject bash "$tmp/scripts/release.sh" --print-version
    grep -Fq "invalid version '$tag'" "$tmp/err"
    reject bash "$tmp/scripts/release.sh" --print-version --bump major
    git -C "$tmp" tag -d "$tag" > /dev/null
done
echo 'Release selection and request tests passed'
