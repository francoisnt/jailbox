#!/bin/bash
# Best-effort run metadata for test runs.
#
# Sourced by the test scripts that create testlog run directories (expects
# JAILBOX_DIR to be set). Each helper appends KEY="value" lines to
# <dir>/meta.env so every uploaded testlog records exactly what it ran
# against. Missing data becomes "unknown" — metadata must never fail a run.
#
# Helpers:
#   write_run_meta  <dir>                     date, jailbox git SHA, host, podman
#   run_meta_editor <dir> <editor-bin>        editor version/commit + remote extension
#   run_meta_reh    <dir> <release> <commit>  VSCodium REH build under test
#   run_meta_image  <dir> <name> <ref>        image ref, resolved digest, os-release

meta_kv() {
    local dir="$1" key="$2" value="$3"
    [[ -n "$value" ]] || value="unknown"
    printf '%s="%s"\n' "$key" "$value" >> "$dir/meta.env" 2>/dev/null || true
}

meta_os_pretty_name() {
    sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' 2>/dev/null | head -1
}

write_run_meta() {
    local dir="$1"
    local date_utc sha dirty host_uname host_os podman_version

    date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    sha="$(git -C "$JAILBOX_DIR" rev-parse HEAD 2>/dev/null || true)"
    dirty="unknown"
    if [[ -n "$sha" ]]; then
        if [[ -n "$(git -C "$JAILBOX_DIR" status --porcelain 2>/dev/null || true)" ]]; then
            dirty="true"
        else
            dirty="false"
        fi
    fi
    host_uname="$(uname -srm 2>/dev/null || true)"
    host_os="$(meta_os_pretty_name < /etc/os-release 2>/dev/null || true)"
    podman_version="$(podman --version 2>/dev/null || true)"

    meta_kv "$dir" RUN_DATE_UTC "$date_utc"
    meta_kv "$dir" JAILBOX_GIT_SHA "$sha"
    meta_kv "$dir" JAILBOX_GIT_DIRTY "$dirty"
    meta_kv "$dir" HOST_UNAME "$host_uname"
    meta_kv "$dir" HOST_OS "$host_os"
    meta_kv "$dir" PODMAN_VERSION "$podman_version"
}

run_meta_editor() {
    local dir="$1" bin="$2"
    local version_output version commit remote_ext

    version_output="$("$bin" --version 2>/dev/null || true)"
    version="$(printf '%s\n' "$version_output" | sed -n 1p)"
    commit="$(printf '%s\n' "$version_output" | sed -n 2p)"
    remote_ext="$("$bin" --list-extensions --show-versions 2>/dev/null \
        | grep -E '^(ms-vscode-remote\.remote-ssh|jeanp413\.open-remote-ssh)@' \
        | head -1 || true)"

    meta_kv "$dir" EDITOR_BIN "$bin"
    meta_kv "$dir" EDITOR_VERSION "$version"
    meta_kv "$dir" EDITOR_COMMIT "$commit"
    meta_kv "$dir" EDITOR_REMOTE_EXTENSION "$remote_ext"
}

run_meta_reh() {
    local dir="$1" release="$2" commit="$3"

    meta_kv "$dir" REH_RELEASE "$release"
    meta_kv "$dir" REH_COMMIT "$commit"
    # The Alpine stage is the only REH probe target; record its artifact URL.
    meta_kv "$dir" REH_DOWNLOAD_URL \
        "https://github.com/VSCodium/vscodium/releases/download/${release}/vscodium-reh-alpine-x64-${release}.tar.gz"
}

run_meta_image() {
    local dir="$1" name="$2" ref="$3"
    local key digest pretty

    key="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
    digest="$(podman image inspect --format '{{index .RepoDigests 0}}' "$ref" 2>/dev/null || true)"
    pretty="$(podman run --rm "$ref" cat /etc/os-release 2>/dev/null | meta_os_pretty_name || true)"

    meta_kv "$dir" "IMAGE_${key}" "$ref"
    meta_kv "$dir" "IMAGE_${key}_DIGEST" "$digest"
    meta_kv "$dir" "IMAGE_${key}_OS" "$pretty"
}
