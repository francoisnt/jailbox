#!/usr/bin/env bash
# Build the private runtime programs. With no arguments, build the checkout.
# --release builds every release program once: OUTPUT_DIR/core/OS-ARCH/jailbox-core
# and OUTPUT_DIR/linux-ARCH/jailbox-container.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if (($# == 0)); then
    case "$(uname -s)/$(uname -m)" in
        Linux/x86_64) platform=linux-amd64 ;;
        Linux/aarch64|Linux/arm64) platform=linux-arm64 ;;
        Darwin/x86_64) platform=darwin-amd64 ;;
        Darwin/arm64) platform=darwin-arm64 ;;
        *) die 'unsupported platform for jailbox programs' ;;
    esac
    output="$ROOT/src/libexec"
    version=dev
elif (($# == 3)) && [[ "$1" = --release ]]; then
    platform=release output=$2 version=$3
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die 'invalid release version'
else
    die 'Usage: scripts/build-programs.sh [--release OUTPUT_DIR VERSION]'
fi

command -v go >/dev/null || die 'Go is required to build jailbox programs'
export CGO_ENABLED=0 GOTOOLCHAIN=local GOWORK=off
# Any patch release of the series named in src/go.mod builds.
series=$(bash "$ROOT/scripts/go-series.sh") || exit 1
installed=$(go env GOVERSION) || die 'could not read the Go version'
patch=${installed#"go$series."}
[[ "$installed" = "go$series.$patch" && "$patch" =~ ^[0-9]+$ ]] ||
    die "building jailbox requires Go $series.x (found $installed)"

mkdir -p -- "$output"
output=$(cd "$output" && pwd -P)
stage=$(mktemp -d "$output/.build.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
cd "$ROOT/src"

build() {
    GOOS=${1%-*} GOARCH=${1#*-} go build -mod=readonly -trimpath \
        -ldflags "-X github.com/francoisnt/jailbox/internal/buildversion.Stamp=jailbox-build-version:$version:" -o "$stage/$2" "$3"
}

for arch in amd64 arm64; do
    mkdir "$stage/linux-$arch"
    build "linux-$arch" "linux-$arch/jailbox-container" ./container/cmd/jailbox-container
done
if [[ "$platform" = release ]]; then
    for target in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
        mkdir -p "$stage/core/$target"
        build "$target" "core/$target/jailbox-core" ./host/core/cmd/jailbox-core
    done
else
    build "$platform" jailbox-core ./host/core/cmd/jailbox-core
    mkdir "$stage/native"
    if [[ "$platform" = linux-* ]]; then
        cp "$stage/$platform/jailbox-container" "$stage/native/jailbox-container"
    else
        build "$platform" native/jailbox-container ./container/cmd/jailbox-container
    fi
fi

# Publish only after all builds have succeeded.
for directory in linux-amd64 linux-arm64 native; do
    [[ -d "$stage/$directory" ]] || continue
    mkdir -p "$output/$directory"
    mv -f -- "$stage/$directory/jailbox-container" "$output/$directory/"
done
if [[ "$platform" = release ]]; then
    rm -rf -- "$output/core"
    mv -- "$stage/core" "$output/core"
else
    mv -f -- "$stage/jailbox-core" "$output/"
fi
