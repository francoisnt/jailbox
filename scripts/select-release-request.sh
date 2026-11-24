#!/bin/bash
# Decode either workflow entry path, then use the same selector as local runs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
args=()
request_object=""
case "${RELEASE_EVENT:-}" in
    push)
        request_kind=${REQUEST_TAG:-}
        if [[ "$request_kind" =~ -([0-9a-f]{40})$ ]]; then
            request_object=${BASH_REMATCH[1]}
            request_kind=${request_kind%-"$request_object"}
        fi
        case "$request_kind" in
            release-request) ;;
            release-request-first-major) args+=(--first-major) ;;
            release-request-bump-patch) args+=(--bump patch) ;;
            release-request-bump-minor) args+=(--bump minor) ;;
            release-request-bump-major) args+=(--bump major) ;;
            *) printf 'Error: invalid release request tag.\n' >&2; exit 2 ;;
        esac
        ;;
    workflow_dispatch)
        case "${FIRST_MAJOR:-false}" in
            true) args+=(--first-major) ;;
            false|"") ;;
            *) printf 'Error: invalid first_major input.\n' >&2; exit 2 ;;
        esac
        case "${BUMP:-auto}" in
            auto) ;;
            *) args+=(--bump "$BUMP") ;;
        esac
        ;;
    *) printf 'Error: unsupported release event.\n' >&2; exit 2 ;;
esac

if [[ "${1:-}" == --cleanup && "$RELEASE_EVENT" == push ]]; then
    expected=${request_object:-${REQUEST_AFTER:-}}
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || exit 0
    ref="refs/tags/$REQUEST_TAG"
    remote=$(git -C "$ROOT_DIR" ls-remote --refs origin "$ref")
    if [[ "$remote" == "$expected"$'\t'"$ref" ]]; then
        git -C "$ROOT_DIR" push --force-with-lease="$ref:$expected" origin ":$ref"
    fi
    exit 0
fi

# shellcheck source=scripts/release.sh
source "$ROOT_DIR/scripts/release.sh"
parse_args "${args[@]}"
select_release_version
printf 'Bump reason: %s\n' "$BUMP_REASON" >&2
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ -n "$request_object" ]]; then
        RELEASE_HIGHLIGHTS=$(python3 "$ROOT_DIR/scripts/lib/release_notes.py" request \
            "$REQUEST_TAG" "$PREVIOUS_TAG" "$PREVIOUS_COMMIT" "$TARGET_COMMIT")
    fi
    {
        printf 'version=%s\ncommit=%s\n' "$SELECTED_VERSION" "$TARGET_COMMIT"
        printf 'previous_tag=%s\nprevious_commit=%s\n' "$PREVIOUS_TAG" "$PREVIOUS_COMMIT"
        printf 'highlights=%s\n' "$RELEASE_HIGHLIGHTS"
    } >> "$GITHUB_OUTPUT"
fi
printf '%s\n' "$SELECTED_VERSION"
