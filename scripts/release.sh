#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

YES=false
DRY_RUN=false
FIRST_MAJOR=false
PRINT_VERSION=false

usage() {
    cat <<EOF_USAGE
Usage: scripts/release.sh [options]

Choose the next version and dispatch the GitHub Actions release workflow.
The workflow re-selects the version with the same policy, runs the full
release gate, and creates the tag and GitHub Release only after all
validation succeeds — a failed gate leaves no stale tag.

Options:
  --yes              Accept defaults without prompting
  --first-major      Release v1.0.0
  --dry-run          Print the selected version without dispatching
  --print-version    Print only the selected version (used by the workflow)
  --help             Show this help

Environment:
  RELEASE_BRANCH     Branch releases must be cut from (default: origin HEAD, or master)
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
            --print-version) PRINT_VERSION=true ;;
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

remote_tag_exists() {
    git -C "$ROOT_DIR" ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

# A failed release push can leave a local tag behind. Refuse to continue
# until it is removed so version selection stays based on published tags.
ensure_no_local_only_version_tags() {
    local tag

    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        if ! remote_tag_exists "$tag"; then
            die "local release tag is not on origin: $tag (delete it with: git tag -d $tag)"
        fi
    done < <(git -C "$ROOT_DIR" tag --list 'v[0-9]*.[0-9]*.[0-9]*')
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

release_branch() {
    local origin_head

    if [ -n "${RELEASE_BRANCH:-}" ]; then
        printf '%s\n' "$RELEASE_BRANCH"
        return 0
    fi

    origin_head="$(git -C "$ROOT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -n "$origin_head" ]; then
        printf '%s\n' "${origin_head#origin/}"
    else
        printf 'master\n'
    fi
}

# Require releases to come from the configured release branch and from the
# exact commit currently published at origin. Pushing only a tag from a local
# commit makes the release hard to review and easy to reproduce incorrectly.
ensure_release_branch_synced() {
    local branch upstream upstream_branch

    branch="$(git -C "$ROOT_DIR" branch --show-current)"
    [ -n "$branch" ] || die "releases must be cut from a branch, not detached HEAD"
    [ "$branch" = "$(release_branch)" ] || \
        die "releases must be cut from $(release_branch) (current branch: $branch)"

    upstream="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    [ -n "$upstream" ] || die "release branch must track origin/$branch"
    upstream_branch="${upstream#origin/}"
    [ "$upstream" = "origin/$branch" ] || \
        die "release branch must track origin/$branch (current upstream: $upstream)"
    [ "$upstream_branch" = "$branch" ] || die "release branch upstream mismatch"

    git -C "$ROOT_DIR" fetch origin "$branch" --tags >/dev/null
    [ "$(git -C "$ROOT_DIR" rev-parse HEAD)" = "$(git -C "$ROOT_DIR" rev-parse "origin/$branch")" ] || \
        die "HEAD must match origin/$branch before releasing"
}

# Select SELECTED_VERSION/BUMP_REASON from published tags and the public API
# diff. Shared by local runs and the CI workflow (--print-version), so both
# always agree on the version policy.
select_release_version() {
    local latest api_change

    latest="$(latest_tag)"
    [ -n "$latest" ] || latest="v0.0.0"

    if [ "$latest" = "v0.0.0" ] && [ "$FIRST_MAJOR" != true ]; then
        SELECTED_VERSION="v0.1.0"
        BUMP_REASON="Initial public release"
    else
        api_change="$(bash "$ROOT_DIR/scripts/public-api-diff.sh" "$latest")"
        select_version "$latest" "$api_change"
    fi
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

# Ask before dispatching the release workflow unless --yes was supplied.
confirm_release() {
    local answer

    [ "$YES" = false ] || return 0
    printf "Dispatch the release workflow for %s? The tag and GitHub Release are created only after the release gate passes. [Y/n]: " "$SELECTED_VERSION"
    read -r answer
    case "$answer" in
        ""|y|Y|yes|YES) ;;
        *) echo "Release cancelled."; exit 0 ;;
    esac
}

# Trigger the release workflow with a plain git push — no gh dependency.
# An ephemeral release-request tag (never matching v*.*.*) starts the
# workflow, which re-selects the version with the same policy, runs the full
# release gate, and creates the version tag and GitHub Release only after the
# gate passes, so a failed run leaves no stale version tag. The workflow
# deletes the request tag when it finishes; --force covers a leftover marker
# from an interrupted run.
dispatch_release() {
    local request_tag

    request_tag="release-request"
    [ "$FIRST_MAJOR" = true ] && request_tag="release-request-first-major"
    git -C "$ROOT_DIR" push --force origin "HEAD:refs/tags/$request_tag"
    echo "Pushed $request_tag; the release workflow will tag and publish after the gate passes."
    echo "Follow it in GitHub Actions (Release workflow)."
}

# Coordinate version selection, confirmation, and workflow dispatch.
main() {
    parse_args "$@"
    require_command git
    require_command bash

    # Machine-readable mode for the workflow's select-version job: version
    # only on stdout, no prompts, no dispatch.
    if [ "$PRINT_VERSION" = true ]; then
        refresh_tags
        select_release_version
        printf '%s\n' "$SELECTED_VERSION"
        return 0
    fi

    if [ "$DRY_RUN" != true ]; then
        ensure_clean_tree
        ensure_origin_remote
        ensure_release_branch_synced
    fi

    refresh_tags
    if [ "$DRY_RUN" != true ]; then
        ensure_no_local_only_version_tags
    fi
    select_release_version
    echo "Selected version: $SELECTED_VERSION"
    echo "Bump reason:"
    printf '%s\n' "$BUMP_REASON" | sed 's/^/  /'

    if [ "$DRY_RUN" = true ]; then
        echo "Dry run: no release dispatched."
        return 0
    fi

    confirm_release
    dispatch_release
}

main "$@"
