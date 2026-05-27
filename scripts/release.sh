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
Real releases always run the full local validation suite before tagging:
  - scripts/lint.sh
  - tests/run

Options:
  --yes              Accept defaults without prompting
  --first-major      Release v1.0.0
  --dry-run          Print the selected version without creating or pushing a tag
  --help             Show this help
EOF_USAGE
}

# Print an error and stop the release flow.
die() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Parse release flags. Version selection itself is policy-driven later.
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

# Ensure tags we create and consume use vMAJOR.MINOR.PATCH.
validate_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$1' (expected vMAJOR.MINOR.PATCH)"
}

# Strip the leading "v" from a SemVer tag.
without_v() {
    printf '%s\n' "${1#v}"
}

# Return the major number from a vMAJOR.MINOR.PATCH tag.
version_major() {
    local major
    IFS=. read -r major _ _ <<< "$(without_v "$1")"
    printf '%s\n' "$major"
}

# Bump one SemVer component and reset lower-order components as needed.
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

# Return the highest local version tag, if any.
latest_tag() {
    git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1
}

# Fetch remote tags so local release decisions include published releases.
refresh_tags() {
    if git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
        git -C "$ROOT_DIR" fetch --tags origin >/dev/null || \
            echo "Warning: could not fetch tags from origin; using local tags only." >&2
    fi
}

# True when any v1+ tag exists; used to keep --first-major one-time only.
has_v1_or_later_tag() {
    local tag
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        [ "$(version_major "$tag")" -lt 1 ] || return 0
    done < <(git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*')
    return 1
}

# Require a clean worktree for real releases. Dry runs intentionally skip this.
ensure_clean_tree() {
    [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ] || \
        die "working tree is not clean (commit or stash changes before releasing)"
}

# Require the remote used for fetching tags and pushing release tags.
ensure_origin_remote() {
    git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1 || \
        die "origin remote is required for releases"
}

# Run mandatory release validation before any confirmation, tag, or push.
run_validation() {
    echo "Running release validation:"
    echo "  scripts/lint.sh"
    bash "$ROOT_DIR/scripts/lint.sh"
    echo "  tests/run"
    require_command podman
    bash "$ROOT_DIR/tests/run"
    echo "Release validation passed."
}

# Map public API diff status to the release bump policy.
suggest_bump() {
    local latest="$1" api_change="$2"

    if [ "$FIRST_MAJOR" = true ]; then
        SUGGESTED_BUMP="major"
        BUMP_REASON="First stable major release requested"
    elif [ "$(version_major "$latest")" -ge 1 ] && [ "$api_change" = removed ]; then
        SUGGESTED_BUMP="major"
        BUMP_REASON="Public API items were removed"
    elif [ "$api_change" = added ] || [ "$api_change" = removed ]; then
        SUGGESTED_BUMP="minor"
        BUMP_REASON="Public API items changed"
    else
        SUGGESTED_BUMP="patch"
        BUMP_REASON="No public API items changed"
    fi
}

# Choose SELECTED_VERSION from latest tag, API change status, and --first-major.
select_version() {
    local latest="$1" api_change="$2" latest_major

    latest_major="$(version_major "$latest")"
    suggest_bump "$latest" "$api_change"

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

# Ask before creating and pushing a release tag unless --yes was supplied.
confirm_release() {
    local answer

    [ "$YES" = false ] || return 0
    printf "Create and push tag %s to origin? This will trigger GitHub Actions release publication. [Y/n]: " "$SELECTED_VERSION"
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) echo "Release cancelled."; exit 0 ;;
    esac
}

# Create the annotated tag and push it; GitHub Actions handles publication.
tag_and_push() {
    git -C "$ROOT_DIR" tag -a "$SELECTED_VERSION" -m "Release $SELECTED_VERSION"
    echo "Created tag $SELECTED_VERSION"
    echo "Pushing tag $SELECTED_VERSION to origin. GitHub Actions will publish the release artifact from this tag."
    git -C "$ROOT_DIR" push origin "$SELECTED_VERSION"
    echo "Pushed tag $SELECTED_VERSION."
}

# Coordinate validation, version selection, confirmation, and tag push.
main() {
    local latest api_change

    parse_args "$@"
    require_command git
    require_command bash
    if [ "$DRY_RUN" != true ]; then
        ensure_clean_tree
        ensure_origin_remote
    fi

    refresh_tags
    latest="$(latest_tag)"
    [ -n "$latest" ] || latest="v0.0.0"

    if [ "$latest" = "v0.0.0" ] && [ "$FIRST_MAJOR" != true ]; then
        SELECTED_VERSION="v0.1.0"
        BUMP_REASON="Initial public release"
    else
        api_change="$(bash "$ROOT_DIR/scripts/public-api-diff.sh" "$latest")"
        select_version "$latest" "$api_change"
    fi
    echo "Selected version: $SELECTED_VERSION"
    echo "Bump reason:"
    printf '%s\n' "$BUMP_REASON" | sed 's/^/  /'

    if [ "$DRY_RUN" = true ]; then
        echo "Dry run: no tag created."
        return 0
    fi

    run_validation
    confirm_release
    tag_and_push
}

main "$@"
