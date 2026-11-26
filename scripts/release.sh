#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

YES=false
DRY_RUN=false
FIRST_MAJOR=false
PRINT_VERSION=false
REQUESTED_BUMP=""
AUTOMATIC_BUMP=""
RELEASE_HIGHLIGHTS=""

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
  --bump LEVEL       Minimum bump: patch, minor, or major (never lowers policy)
  --dry-run          Preview the selected version and release notes without dispatching
                     Use --yes to skip the bump prompt for unattended previews
  --print-version    Print only the selected version
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

# Run Git from the repository root so the working directory is also correct
# when Git is provided by jailbox command forwarding.
release_git() {
    (cd "$ROOT_DIR" && git "$@")
}

# Parse release flags. Version selection itself is policy-driven later.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) YES=true ;;
            --dry-run) DRY_RUN=true ;;
            --first-major) FIRST_MAJOR=true ;;
            --bump)
                [ -z "$REQUESTED_BUMP" ] || die '--bump may only be supplied once'
                validate_bump "${2:-}"
                REQUESTED_BUMP=$2
                shift
                ;;
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
    [[ "$FIRST_MAJOR" != true || -z "$REQUESTED_BUMP" ]] || die '--first-major and --bump cannot be combined'
}

validate_bump() {
    case "$1" in
        patch|minor|major) ;;
        *) die 'bump must be patch, minor, or major' ;;
    esac
}

# Ensure tags we create and consume use vMAJOR.MINOR.PATCH.
validate_version() {
    [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "invalid version '$1' (expected vMAJOR.MINOR.PATCH without leading zeros)"
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
    release_git for-each-ref --count=1 --sort=-v:refname \
        --format='%(refname:strip=2)' 'refs/tags/v[0-9]*.[0-9]*.[0-9]*'
}

# Fetch remote tags so local release decisions include published releases.
refresh_tags() {
    if release_git remote get-url origin >/dev/null 2>&1; then
        release_git fetch --tags origin >/dev/null || \
            echo "Warning: could not fetch tags from origin; using local tags only." >&2
    fi
}

remote_tag_exists() {
    release_git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

# A failed release push can leave a local tag behind. Refuse to continue
# until it is removed so version selection stays based on published tags.
ensure_no_local_only_version_tags() {
    local tag tags status

    tags=$(release_git tag --list 'v[0-9]*.[0-9]*.[0-9]*') || die 'could not inspect local release tags'
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        if remote_tag_exists "$tag"; then
            continue
        else
            status=$?
            [ "$status" -eq 2 ] || die "could not inspect remote release tag: $tag"
            die "local release tag is not on origin: $tag (delete it with: git tag -d $tag)"
        fi
    done <<< "$tags"
}

# True when any v1+ tag exists; used to keep --first-major one-time only.
has_v1_or_later_tag() {
    local tag tags
    tags=$(release_git tag --list 'v[0-9]*.[0-9]*.[0-9]*') || return 2
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        [ "$(version_major "$tag")" -lt 1 ] || return 0
    done <<< "$tags"
    return 1
}

# Require a clean worktree for real releases. Dry runs intentionally skip this.
ensure_clean_tree() {
    local status
    status=$(release_git status --porcelain) || die 'could not inspect working tree'
    [ -z "$status" ] || \
        die "working tree is not clean (commit or stash changes before releasing)"
}

# Require the remote used for fetching tags and pushing release tags.
ensure_origin_remote() {
    release_git remote get-url origin >/dev/null 2>&1 || \
        die "origin remote is required for releases"
}

release_branch() {
    local origin_head

    if [ -n "${RELEASE_BRANCH:-}" ]; then
        printf '%s\n' "$RELEASE_BRANCH"
        return 0
    fi

    origin_head="$(release_git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
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

    branch="$(release_git branch --show-current)"
    [ -n "$branch" ] || die "releases must be cut from a branch, not detached HEAD"
    [ "$branch" = "$(release_branch)" ] || \
        die "releases must be cut from $(release_branch) (current branch: $branch)"

    upstream="$(release_git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    [ -n "$upstream" ] || die "release branch must track origin/$branch"
    upstream_branch="${upstream#origin/}"
    [ "$upstream" = "origin/$branch" ] || \
        die "release branch must track origin/$branch (current upstream: $upstream)"
    [ "$upstream_branch" = "$branch" ] || die "release branch upstream mismatch"

    release_git fetch origin "$branch" --tags >/dev/null
    [ "$(release_git rev-parse HEAD)" = "$(release_git rev-parse "origin/$branch")" ] || \
        die "HEAD must match origin/$branch before releasing"
}

# Select SELECTED_VERSION/BUMP_REASON from published tags and the public API
# diff. Local requests and CI both use this selector.
select_release_version() {
    TARGET_COMMIT=$(release_git rev-parse --verify 'HEAD^{commit}') ||
        die 'could not resolve the release commit'
    PREVIOUS_TAG=$(latest_tag) || die 'could not inspect latest release tag'
    PREVIOUS_COMMIT=""
    API_CHANGE=initial
    if [ -n "$PREVIOUS_TAG" ]; then
        validate_version "$PREVIOUS_TAG"
        PREVIOUS_COMMIT=$(release_git rev-parse --verify "refs/tags/$PREVIOUS_TAG^{commit}") ||
            die 'could not resolve the previous release commit'
        API_CHANGE=$(bash "$ROOT_DIR/scripts/public-api-diff.sh" "$PREVIOUS_COMMIT" "$TARGET_COMMIT") ||
            die 'could not compare public API'
    fi
    select_version "${PREVIOUS_TAG:-v0.0.0}" "$API_CHANGE"
}

# Map public API diff status to the release bump policy.
suggest_bump() {
    local latest="$1" api_change="$2"

    if [ "$api_change" = initial ]; then
        SUGGESTED_BUMP="minor"
        BUMP_REASON="Initial public release"
    elif [ "$(version_major "$latest")" -ge 1 ] && [ "$api_change" = removed ]; then
        SUGGESTED_BUMP="major"
        BUMP_REASON="Public API items were removed"
    elif [ "$api_change" = removed ]; then
        SUGGESTED_BUMP="minor"
        BUMP_REASON="Public API items were removed before v1.0.0"
    elif [ "$api_change" = added ]; then
        BUMP_REASON="Public API items were added"
        if [ "$(version_major "$latest")" -ge 1 ]; then
            SUGGESTED_BUMP="minor"
        else
            SUGGESTED_BUMP="patch"
            BUMP_REASON+=" before v1.0.0"
        fi
    else
        SUGGESTED_BUMP="patch"
        BUMP_REASON="Public API items were unchanged"
    fi
}

# Choose SELECTED_VERSION from latest tag, API change status, and --first-major.
select_version() {
    local latest="$1" api_change="$2" latest_major status

    latest_major="$(version_major "$latest")"
    suggest_bump "$latest" "$api_change"
    AUTOMATIC_BUMP=$SUGGESTED_BUMP
    case "$REQUESTED_BUMP:$SUGGESTED_BUMP" in
        major:patch|major:minor|minor:patch)
            SUGGESTED_BUMP=$REQUESTED_BUMP
            BUMP_REASON="Requested minimum bump $REQUESTED_BUMP (policy: $BUMP_REASON)"
            ;;
    esac

    if [ "$FIRST_MAJOR" = true ]; then
        [ "$latest_major" -lt 1 ] || die "--first-major is only valid before v1.0.0"
        if has_v1_or_later_tag; then
            die "--first-major has already been used; a v1+ tag exists"
        else
            status=$?
            [ "$status" -eq 1 ] || die 'could not inspect major release tags'
        fi
        SELECTED_VERSION="v1.0.0"
        BUMP_REASON="First stable major release requested"
    else
        SELECTED_VERSION="$(bump_version "$latest" "$SUGGESTED_BUMP")"
    fi

    validate_version "$SELECTED_VERSION"
    if release_git rev-parse --verify --quiet "refs/tags/$SELECTED_VERSION" >/dev/null; then
        die "tag already exists: $SELECTED_VERSION"
    else
        status=$?
        [ "$status" -eq 1 ] || die 'could not inspect selected release tag'
    fi
}

# Human review can raise the policy result before the final yes/no prompt.
choose_bump() {
    local answer
    [[ "$YES" == false && "$FIRST_MAJOR" == false ]] || return 0
    printf 'Automatic bump: %s.\n' "$AUTOMATIC_BUMP"
    if [[ -n "$REQUESTED_BUMP" ]]; then
        printf 'Requested minimum bump: %s.\n' "$REQUESTED_BUMP"
    fi
    printf 'Selected version after applying the minimum: %s.\n' "$SELECTED_VERSION"
    printf 'Press Enter to keep it, or request a higher bump (patch/minor/major): '
    read -r answer || die 'could not read bump selection'
    [[ -n "$answer" ]] || return 0
    validate_bump "$answer"
    # An interactive answer may raise, but cannot undo an explicit minimum.
    case "$REQUESTED_BUMP:$answer" in
        major:*|minor:patch) ;;
        *) REQUESTED_BUMP=$answer ;;
    esac
    select_version "${PREVIOUS_TAG:-v0.0.0}" "$API_CHANGE"
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

# Push the annotation directly. The ref includes its object ID so a workflow
# can identify the triggering annotation even when a ref has been overwritten.
dispatch_release() {
    local request_tag tagger request_object

    request_tag="release-request"
    [ "$FIRST_MAJOR" = true ] && request_tag="release-request-first-major"
    [ -z "$REQUESTED_BUMP" ] || request_tag="release-request-bump-$REQUESTED_BUMP"
    tagger=$(release_git -c user.name='jailbox release request' \
        -c user.email='release-request@jailbox.invalid' var GIT_COMMITTER_IDENT) ||
        die 'could not create release request tagger'
    request_object=$(
        printf 'object %s\ntype commit\ntag %s\ntagger %s\n\njailbox release highlights v1\n%s\n%s\n%s\n%s\n' \
            "$TARGET_COMMIT" "$request_tag" "$tagger" \
            "$PREVIOUS_TAG" "$PREVIOUS_COMMIT" "$TARGET_COMMIT" "$RELEASE_HIGHLIGHTS" |
            release_git mktag
    ) || die 'could not create annotated release request'
    request_tag+="-$request_object"
    release_git push origin "$request_object:refs/tags/$request_tag"
    echo "Pushed $request_tag; the release workflow will tag and publish after the gate passes."
    echo "Follow it in GitHub Actions (Release workflow)."
}

# Coordinate version selection, confirmation, and workflow dispatch.
main() {
    local status

    parse_args "$@"
    require_command git
    require_command bash

    # Machine-readable output for callers that only need the version.
    if [ "$PRINT_VERSION" = true ]; then
        refresh_tags
        select_release_version
        printf '%s\n' "$SELECTED_VERSION"
        return 0
    fi

    require_command python3
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
    choose_bump
    RELEASE_HIGHLIGHTS=$(python3 -B "$ROOT_DIR/scripts/lib/release_notes.py" \
        draft "$PREVIOUS_COMMIT" "$TARGET_COMMIT") || {
        status=$?
        if [[ "$status" == 130 ]]; then
            return 130
        fi
        die 'could not prepare release highlights'
    }
    printf 'Selected version: %s\nBump reason: %s\n\n' "$SELECTED_VERSION" "$BUMP_REASON"
    RELEASE_HIGHLIGHTS=$RELEASE_HIGHLIGHTS python3 -B "$ROOT_DIR/scripts/lib/release_notes.py" render \
        "$SELECTED_VERSION" "$PREVIOUS_TAG" "$PREVIOUS_COMMIT" "$TARGET_COMMIT"

    if [ "$DRY_RUN" = true ]; then
        echo "Dry run: no release dispatched."
        return 0
    fi

    confirm_release
    dispatch_release
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
