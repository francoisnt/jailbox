#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

YES=false
DRY_RUN=false
FIRST_MAJOR=false

usage() {
    cat <<EOF_USAGE
Usage: scripts/release.sh [options]

Choose the next version, create an annotated git tag, and push it.
GitHub Actions publishes the release tarball from the pushed tag.

Options:
  --yes              Accept defaults without prompting
  --first-major      Release v1.0.0; before this flag, pre-v1 bumps are patch-only
  --dry-run          Print the selected version without creating or pushing a tag
  --help             Show this help
EOF_USAGE
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) YES=true ;;
            --dry-run) DRY_RUN=true ;;
            --first-major) FIRST_MAJOR=true ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

validate_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$1' (expected vMAJOR.MINOR.PATCH)"
}

without_v() {
    printf '%s\n' "${1#v}"
}

version_major() {
    local major
    IFS=. read -r major _ _ <<< "$(without_v "$1")"
    printf '%s\n' "$major"
}

bump_version() {
    local major minor patch
    IFS=. read -r major minor patch <<< "$(without_v "$1")"

    case "$2" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
    esac

    printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
}

latest_tag() {
    git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1
}

has_v1_or_later_tag() {
    local tag
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        [ "$(version_major "$tag")" -lt 1 ] || return 0
    done < <(git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*')
    return 1
}

ensure_clean_tree() {
    [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] || \
        die "working tree is not clean (commit or stash changes before releasing)"
}

run_checks() {
    bash -n "$ROOT_DIR/install.sh" "$ROOT_DIR/jailbox" "$ROOT_DIR"/lib/*.sh "$ROOT_DIR"/scripts/*.sh
    sh -n "$ROOT_DIR"/install/*.sh
}

file_at_ref() {
    local ref path
    ref="$1"
    path="$2"

    if [ -z "$ref" ]; then
        cat "$ROOT_DIR/$path"
    else
        git -C "$ROOT_DIR" show "$ref:$path" 2>/dev/null || true
    fi
}

public_api_values() {
    local ref array_name

    ref="$1"
    array_name="$2"

    file_at_ref "$ref" "lib/public-api.sh" |
        awk -v array="$array_name" '
            $0 ~ "^[[:space:]]*" array "=[(]" { in_array = 1; next }
            in_array && /^[[:space:]]*[)]/ { in_array = 0; next }
            in_array {
                gsub(/#.*/, "")
                gsub(/["'\''"]/, "")
                for (i = 1; i <= NF; i++) print $i
            }
        ' |
        sed '/^$/d' |
        sort -u
}

public_api_names() {
    {
        public_api_values "$1" "CONFIG_SCALAR_KEYS"
        public_api_values "$1" "CONFIG_ARRAY_KEYS"
        public_api_values "$1" "CLI_FLAGS"
    } | sort -u
}

describe_api_changes() {
    local action="$1"
    sed "s/^/$action public API item: /"
}

detect_stable_bump() {
    local base_ref removed added

    base_ref="$1"
    removed=$(comm -23 <(public_api_names "$base_ref") <(public_api_names "") | describe_api_changes "Removed")
    added=$(comm -13 <(public_api_names "$base_ref") <(public_api_names "") | describe_api_changes "Added")

    if [ -n "$removed" ]; then
        SUGGESTED_BUMP="major"
        BUMP_REASON="$removed"
    elif [ -n "$added" ]; then
        SUGGESTED_BUMP="minor"
        BUMP_REASON="$added"
    else
        SUGGESTED_BUMP="patch"
        BUMP_REASON="No public API items changed"
    fi
}

suggest_bump() {
    local latest="$1" base_ref="$2"

    if [ "$FIRST_MAJOR" = true ]; then
        SUGGESTED_BUMP="major"
        BUMP_REASON="First stable major release requested"
    elif [ "$(version_major "$latest")" -lt 1 ]; then
        SUGGESTED_BUMP="patch"
        BUMP_REASON="Pre-v1 release: patch-only until --first-major releases v1.0.0"
    else
        detect_stable_bump "$base_ref"
    fi
}

select_version() {
    local latest="$1" base_ref="$2" latest_major

    latest_major="$(version_major "$latest")"
    suggest_bump "$latest" "$base_ref"

    if [ "$FIRST_MAJOR" = true ]; then
        [ "$latest_major" -lt 1 ] || die "--first-major is only valid before v1.0.0"
        ! has_v1_or_later_tag || die "--first-major has already been used; a v1+ tag exists"
        SELECTED_VERSION="v1.0.0"
    else
        SELECTED_VERSION="$(bump_version "$latest" "$SUGGESTED_BUMP")"
    fi

    validate_version "$SELECTED_VERSION"
    ! git -C "$ROOT_DIR" rev-parse "$SELECTED_VERSION" >/dev/null 2>&1 || \
        die "tag already exists: $SELECTED_VERSION"
}

confirm_release() {
    local answer

    [ "$YES" = false ] || return 0
    printf "Create and push tag %s to origin? [Y/n]: " "$SELECTED_VERSION"
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) echo "Release cancelled."; exit 0 ;;
    esac
}

tag_and_push() {
    git -C "$ROOT_DIR" tag -a "$SELECTED_VERSION" -m "Release $SELECTED_VERSION"
    echo "Created tag $SELECTED_VERSION"
    git -C "$ROOT_DIR" push origin "$SELECTED_VERSION"
    echo "Pushed tag $SELECTED_VERSION. GitHub Actions will publish the release artifact."
}

main() {
    local latest base_ref

    parse_args "$@"
    ensure_clean_tree
    run_checks

    latest="$(latest_tag)"
    base_ref="$latest"
    [ -n "$latest" ] || latest="v0.0.0"

    select_version "$latest" "$base_ref"
    echo "Selected version: $SELECTED_VERSION"
    echo "Reason:"
    printf '%s\n' "$BUMP_REASON" | sed 's/^/  /'

    if [ "$DRY_RUN" = true ]; then
        echo "Dry run: no tag created."
        return 0
    fi

    confirm_release
    tag_and_push
}

main "$@"
