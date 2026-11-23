#!/bin/bash
# The canary files one issue per newer stable base-image series, the bump
# helper updates one pin, and generated files follow the pins in versions.env.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

checkout=$tmp/checkout
script=$checkout/scripts/canary-base-images.sh
generator=$checkout/scripts/gen-tested-matrix.sh
mkdir -p "$checkout/scripts/lib" "$checkout/docs" "$checkout/src/container/tinyproxy" "$checkout/src/host/frontend" "$tmp/bin"
cp "$ROOT/scripts/canary-base-images.sh" "$ROOT/scripts/bump-base-image.sh" "$ROOT/scripts/gen-tested-matrix.sh" "$checkout/scripts/"
cp "$ROOT/scripts/lib/base-images.sh" "$checkout/scripts/lib/"
cp "$ROOT/tests/fixtures/base-image-updates/curl.sh" "$tmp/bin/curl"
cp "$ROOT/tests/fixtures/base-image-updates/gh.sh" "$tmp/bin/gh"
chmod 755 "$tmp/bin/curl" "$tmp/bin/gh"
write_pins() {
    cat > "$checkout/versions.env" <<PINS
BASE_IMAGE_ALPINE="$1"    # kept comment
BASE_IMAGE_DEBIAN="$2"
BASE_IMAGE_FEDORA="fedora:41"
CODE_VERSION="1.0"
CODIUM_VERSION="2.0"
CODIUM_COMMIT="fixture"
REMOTE_SSH_VERSION="3.0"
OPEN_REMOTE_SSH_VERSION="4.0"
PINS_LAST_VERIFIED="2000-01-01"
PINS
}
write_pins alpine:3.24 debian:12
printf 'FROM alpine:3.24\n' > "$checkout/src/container/tinyproxy/Containerfile"
printf '# Template\nFROM docker.io/library/debian:12\nRUN true\n' > "$checkout/src/host/frontend/Containerfile.template"
printf '%s\n' '<!-- BEGIN GENERATED: tested-matrix -->' '<!-- END GENERATED: tested-matrix -->' > "$checkout/docs/development.md"
bash "$generator" --write

# --write carries the Alpine and Debian pins into the proxy and init template
# FROM lines, and --check names a stale copy.
write_pins alpine:3.25 debian:13
if bash "$generator" --check > "$tmp/log" 2>&1; then
    printf 'Stale generated files passed the check\n' >&2
    exit 1
fi
grep -Fq 'src/container/tinyproxy/Containerfile FROM (alpine:3.24)' "$tmp/log"
grep -Fq 'src/host/frontend/Containerfile.template FROM (docker.io/library/debian:12)' "$tmp/log"
bash "$generator" --write
bash "$generator" --check
grep -Fxq 'FROM alpine:3.25' "$checkout/src/container/tinyproxy/Containerfile"
[[ $(cat "$checkout/src/host/frontend/Containerfile.template") == $'# Template\nFROM docker.io/library/debian:13\nRUN true' ]]
grep -Fxq '| Debian 13 | ✅ | ✅ |' "$checkout/docs/development.md"
write_pins alpine:3.24 debian:12
bash "$generator" --write

# The bump helper works in a Git checkout; give it an isolated dummy identity.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
commit() {
    git -C "$checkout" -c user.name='Base image test' -c user.email='base-image-test@example.invalid' \
        commit -qam "$1"
}
unchanged() { [[ -z $(git -C "$checkout" status --porcelain) ]]; }
git -C "$checkout" init -q
git -C "$checkout" add .
commit fixture
base=$(git -C "$checkout" rev-parse HEAD)
bump=$checkout/scripts/bump-base-image.sh
template=$checkout/src/host/frontend/Containerfile.template
expect_failure() {
    local message=$1
    shift
    if bash "$bump" "$@" > "$tmp/log" 2>&1; then
        printf 'bump %s succeeded\n' "$*" >&2
        exit 1
    fi
    grep -Fq -- "$message" "$tmp/log"
}

# It accepts one numbered release of a known image.
for bad in '' 'debian' 'debian:13;touch x' 'ubuntu:24' 'alpine:3' 'debian:13.1' 'fedora:045'; do
    expect_failure 'usage: bump-base-image.sh IMAGE:VERSION, with a numbered alpine/debian/fedora release' "$bad"
done
expect_failure 'usage:' debian:13 alpine:3.25
unchanged

# It refuses uncommitted changes to the pin file or a generated file, so a
# later restore cannot discard anyone's edits.
for file in versions.env docs/development.md src/host/frontend/Containerfile.template; do
    printf '# edit\n' >> "$checkout/$file"
    expect_failure 'commit or stash your staged or unstaged changes' debian:13
    grep -Fxq '# edit' "$checkout/$file"
    git -C "$checkout" checkout -q -- "$file"
done
# A staged edit behind a worktree copy that matches HEAD is refused and kept.
printf '# staged\n' >> "$checkout/docs/development.md"
git -C "$checkout" add docs/development.md
git -C "$checkout" show HEAD:docs/development.md > "$checkout/docs/development.md"
chmod 444 "$template"
expect_failure 'commit or stash your staged or unstaged changes' debian:13
git -C "$checkout" show :docs/development.md | grep -Fxq '# staged'
chmod 644 "$template"
git -C "$checkout" reset -q --hard "$base"

# A generated file that is missing, has no FROM line, or cannot be written
# fails the bump and leaves every file as committed.
git -C "$checkout" rm -q "$template"
commit 'remove template'
expect_failure 'must all be tracked by Git' debian:13
unchanged
git -C "$checkout" reset -q --hard "$base"
printf '# Template\nRUN true\n' > "$template"
commit 'template without FROM'
expect_failure 'Containerfile.template has no FROM line to update' debian:13
grep -Fq 'the changes were undone' "$tmp/log"
unchanged
git -C "$checkout" reset -q --hard "$base"
chmod 444 "$template"
# Root can write a read-only file, so the case cannot fail there.
if [[ ! -w "$template" ]]; then
    expect_failure 'the changes were undone' debian:13
    unchanged
    grep -Fxq 'BASE_IMAGE_DEBIAN="debian:12"' "$checkout/versions.env"
    # Called directly, as the editor canary does, --write also changes nothing.
    write_pins alpine:3.25 debian:13
    if bash "$generator" --write > "$tmp/log" 2>&1; then
        printf 'The generator wrote around a read-only template\n' >&2
        exit 1
    fi
    grep -Fq 'src/host/frontend/Containerfile.template is not writable; nothing was changed' "$tmp/log"
    [[ $(git -C "$checkout" status --porcelain) == ' M versions.env' ]]
    git -C "$checkout" checkout -q -- versions.env
fi
chmod 644 "$template"
unchanged

# A valid bump changes only that pin, keeps its comment, and regenerates the
# derived files.
bash "$bump" alpine:3.25 > "$tmp/log" 2>&1
grep -Fxq 'BASE_IMAGE_ALPINE="alpine:3.25"    # kept comment' "$checkout/versions.env"
[[ $(grep -c '^BASE_IMAGE_' "$checkout/versions.env") -eq 3 ]]
grep -Fxq 'BASE_IMAGE_DEBIAN="debian:12"' "$checkout/versions.env"
grep -Fxq 'FROM alpine:3.25' "$checkout/src/container/tinyproxy/Containerfile"
bash "$generator" --check
git -C "$checkout" reset -q --hard "$base"

export PATH="$tmp/bin:$PATH" GH_ISSUES="$tmp/issues" GH_BODIES="$tmp/bodies"
: > "$GH_ISSUES"
alpine='Canary: newer stable base image alpine:3.25'
debian='Canary: newer stable base image debian:13'
fedora='Canary: newer stable base image fedora:45'

# Each newer series gets one issue; reruns, including after an issue is
# closed, file nothing new.
bash "$script" > "$tmp/log" 2>&1
[[ $(cat "$GH_ISSUES") == "$alpine"$'\n'"$debian"$'\n'"$fedora" ]]
# Each body names the bump command, and only shipped images ask for a release note.
for ref in alpine:3.25 debian:13 fedora:45; do
    grep -Fq "run \`bash scripts/bump-base-image.sh $ref\`" "$GH_BODIES"
done
grep -Fq 'Alpine is the base of the egress proxy image that jailbox builds, so mention the new proxy base in the release notes.' "$GH_BODIES"
grep -Fq 'Debian is the base of the Containerfile that jailbox init writes, so mention the new default in the release notes.' "$GH_BODIES"
grep -Fq 'Fedora is used only for test coverage; no release note is needed.' "$GH_BODIES"
[[ $(grep -c 'release notes' "$GH_BODIES") -eq 2 ]]
bash "$script" > "$tmp/log" 2>&1
[[ $(wc -l < "$GH_ISSUES") -eq 3 ]]

# Current or older stable releases file nothing.
: > "$GH_ISSUES"
MANIFESTS=current bash "$script" > "$tmp/log" 2>&1
ALPINE_MANIFEST=older MANIFESTS=current bash "$script" > "$tmp/log" 2>&1
[[ ! -s "$GH_ISSUES" ]]

# Lookup, tag, and pin errors fail the run but still report the other images.
if GH_LIST_FAIL=1 bash "$script" > "$tmp/log" 2>&1; then
    printf 'A failed issue lookup was accepted\n' >&2
    exit 1
fi
[[ ! -s "$GH_ISSUES" ]]
if ALPINE_MANIFEST=ambiguous bash "$script" > "$tmp/log" 2>&1; then
    printf 'Ambiguous stable tags were accepted\n' >&2
    exit 1
fi
grep -Fq 'could not identify the numbered stable alpine image' "$tmp/log"
[[ $(cat "$GH_ISSUES") == "$debian"$'\n'"$fedora" ]]
: > "$GH_ISSUES"
write_pins alpine:latest debian:12
if bash "$script" > "$tmp/log" 2>&1; then
    printf 'An unnumbered pin was accepted\n' >&2
    exit 1
fi
grep -Fq 'BASE_IMAGE_ALPINE must name a numbered alpine release' "$tmp/log"
[[ $(cat "$GH_ISSUES") == "$debian"$'\n'"$fedora" ]]
printf 'PASS: generated image pins, one issue per newer stable series, and failure reporting\n'
