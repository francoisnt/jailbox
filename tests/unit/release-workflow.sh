#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow=${1:-"$ROOT/.github/workflows/release.yml"}
canary=${2:-"$ROOT/.github/workflows/canary.yml"}

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
grep -Fq 'needs: [select-version, previous-gates, test-gates]' "$workflow"
grep -Fq 'uses: ./.github/workflows/test-gates.yml' "$workflow"
grep -Fq "if: needs.previous-gates.outputs.reuse != 'true'" "$workflow"
grep -Fq 'run: python3 scripts/lib/release-gates.py select' "$workflow"
grep -Fq '  actions: read' "$workflow"
gates="$ROOT/.github/workflows/test-gates.yml"
grep -Fq '    needs: [lint, portable, runtime, matrix, matrix-coverage, editor]' "$gates"
# ShellCheck runs once in its own gate; portable environments do not repeat it.
lint_job=$(awk '/^  lint:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$gates")
grep -Fxq '        run: bash tests/run lint' <<< "$lint_job"
grep -Fq 'path: testlog/shellcheck-cache/success' <<< "$lint_job"
portable_job=$(awk '/^  portable:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$gates")
if grep -Fq 'shellcheck-cache' <<< "$portable_job"; then exit 1; fi
grep -Fq '      success() && inputs.run_editor &&' "$gates"
# Only a full, unmodified matrix produces evidence, and every run includes it.
grep -Fq "      inputs.lifecycle_jobs == '' &&" "$gates"
if grep -Fq 'matrix-scope' "$gates" "$ROOT/.github/workflows/pr-checks.yml"; then exit 1; fi
# shellcheck disable=SC2016 # Literal GitHub Actions expression.
grep -Fq 'JAILBOX_LIFECYCLE_SHARD: ${{ matrix.shard }}/8' "$gates"
grep -Fxq '        shard: [1, 2, 3, 4, 5, 6, 7, 8]' "$gates"
# Shards cannot see each other, so a later job checks coverage across all logs.
coverage_job=$(awk '/^  matrix-coverage:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$gates")
grep -Fxq '    needs: matrix' <<< "$coverage_job"
if grep -Fq 'if:' <<< "$coverage_job"; then exit 1; fi
grep -Fxq '          pattern: matrix-logs-*' <<< "$coverage_job"
grep -Fxq '        run: bash tests/ci/check-matrix-coverage.sh 8 matrix-logs' <<< "$coverage_job"
grep -Fq "inputs.code_version == '' && inputs.codium_version == ''" "$gates"
grep -Fq "inputs.remote_ssh_version == '' && inputs.open_remote_ssh_version == ''" "$gates"
grep -Fq 'run: python3 scripts/lib/release-gates.py record' "$gates"

if grep -Eq 'run_editor: *false' "$workflow"; then exit 1; fi
grep -Fxq '            dist/install.sh' "$workflow"
awk -f "$ROOT/tests/lib/release-order.awk" "$workflow"
# shellcheck disable=SC2016 # Match the validator invocation literally.
grep -Fq 'bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$DIST_DIR"' "$ROOT/scripts/build-tarball.sh"
grep -Fq 'git push origin ":refs/tags/' "$workflow"
# Scope assertions to the recorder jobs: unrelated success guards do not count.
release_record=$(awk '/^  record-compatibility:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$workflow")
canary_record=$(awk '/^  record-compatibility:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$canary")
grep -Fxq '    needs: [select-version, publish]' <<< "$release_record"
grep -Fxq "    if: always() && needs.test-gate.result == 'success' && github.ref == 'refs/heads/master'" <<< "$canary_record"
grep -Fxq '    needs: [resolve, codium-commit, test-gate, report]' <<< "$canary_record"
# shellcheck disable=SC2016 # Literal GitHub Actions expressions.
grep -Fq 'JAILBOX_CODIUM_COMMIT: ${{ needs.codium-commit.outputs.codium_commit }}' <<< "$canary_record"
for job in "$release_record" "$canary_record"; do
    # shellcheck disable=SC2016 # Checkout must not depend on the ephemeral request tag.
    grep -Fxq '          ref: ${{ github.sha }}' <<< "$job"
    if grep -Fq '    concurrency:' <<< "$job"; then
        echo 'Compatibility recorder must not cancel queued results.' >&2
        exit 1
    fi
done
echo 'Release workflow contract passed'
