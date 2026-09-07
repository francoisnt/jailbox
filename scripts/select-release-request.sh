#!/bin/bash
# Decode either workflow entry path, then use the same selector as local runs.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
args=(--print-version)
case "${RELEASE_EVENT:-}" in
    push)
        case "${REQUEST_TAG:-}" in
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
exec bash "$ROOT_DIR/scripts/release.sh" "${args[@]}"
