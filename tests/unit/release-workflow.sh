#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow=${1:-"$ROOT/.github/workflows/release.yml"}

for tag in release-request release-request-first-major \
    release-request-bump-patch release-request-bump-minor release-request-bump-major; do
    [[ "$tag" != v[0-9]*.[0-9]*.[0-9]* ]]
    grep -Fxq "      - \"$tag\"" "$workflow"
done

# Ensure the real workflow connects both inputs to the tested decoder, keeps
# all gates as publication prerequisites, and builds only before tagging.
grep -Fq 'bash scripts/select-release-request.sh' "$workflow"
# shellcheck disable=SC2016 # These are literal GitHub Actions expressions.
for binding in 'RELEASE_EVENT: ${{ github.event_name }}' \
    'REQUEST_TAG: ${{ github.ref_name }}' 'FIRST_MAJOR: ${{ inputs.first_major }}' \
    'BUMP: ${{ inputs.bump }}'; do
    grep -Fq "$binding" "$workflow"
done
grep -Fq 'needs: [select-version, test-gates]' "$workflow"
grep -Fq 'uses: ./.github/workflows/test-gates.yml' "$workflow"
if grep -Eq 'run_editor: *false' "$workflow"; then exit 1; fi
awk '
    /bash scripts\/build-tarball.sh/ { if (tag || publish) exit 1; build++ }
    /git tag -a/ { if (build != 1) exit 1; tag++ }
    /git push origin "\$VERSION"/ { if (tag != 1) exit 1; pushed++ }
    /uses: softprops\/action-gh-release/ { if (pushed != 1) exit 1; publish++ }
    END { if (build != 1 || tag != 1 || pushed != 1 || publish != 1) exit 1 }
' "$workflow"
# shellcheck disable=SC2016 # Match the validator invocation literally.
grep -Fq 'bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$DIST_DIR"' "$ROOT/scripts/build-tarball.sh"
grep -Fq 'git push origin ":refs/tags/' "$workflow"
echo 'Release workflow contract passed'
