#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow=${1:-"$ROOT/.github/workflows/release.yml"}
canary=${2:-"$ROOT/.github/workflows/release-check.yml"}

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
grep -Fq 'needs: [select-version, previous-gates, test-gates, package, install]' "$workflow"
grep -Fq 'uses: ./.github/workflows/test-gates.yml' "$workflow"
grep -Fq "if: needs.previous-gates.outputs.reuse != 'true'" "$workflow"
grep -Fq 'run: python3 scripts/lib/release-gates.py select' "$workflow"
grep -Fq '  actions: read' "$workflow"
gates=${3:-"$ROOT/.github/workflows/test-gates.yml"}
grep -Fq '    needs: [go-version, lint, portable, runtime, matrix, matrix-coverage, editor]' "$gates"
# ShellCheck runs once in its own gate; portable environments do not repeat it.
lint_job=$(awk '/^  lint:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$gates")
grep -Fxq '        run: bash tests/run lint' <<< "$lint_job"
grep -Fq 'path: testlog/shellcheck-cache/success' <<< "$lint_job"
portable_job=$(awk '/^  portable:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$gates")
if grep -Fq 'shellcheck-cache' <<< "$portable_job"; then exit 1; fi
grep -Fq '      success() && inputs.run_editor &&' "$gates"
# Only a full, unmodified matrix produces evidence, and every run includes it.
grep -Fq "      inputs.lifecycle_jobs == ''" "$gates"
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
grep -Fq 'run: python3 scripts/lib/release-gates.py record' "$gates"

if grep -Eq 'run_editor: *false' "$workflow"; then exit 1; fi
grep -Fxq '            dist/install.sh' "$workflow"
for platform in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
    grep -Fxq "            platform: $platform" "$workflow"
done
grep -Fq "needs.install.result == 'success'" "$workflow"
# One gate run and its release package use one exact Go release: the newest
# patch of the src/go.mod series, whatever form Go's tools give the directive.
for file in "$workflow" "$gates"; do
    if grep -Fq 'go-version-file:' "$file" || grep -Fq 'check-latest:' "$file"; then exit 1; fi
done
# shellcheck disable=SC2016 # Match the workflow expression literally.
resolved='${{ needs.go-version.outputs.version }}'
[[ $(grep -cF "go-version: $resolved" "$gates") = 5 ]]
[[ $(grep -cFx '    needs: go-version' "$gates") = 5 ]]
# shellcheck disable=SC2016 # Match the workflow command literally.
grep -Fq 'version=$(bash scripts/go-version.sh "$REQUESTED")' "$gates"
[[ $(grep -cF "go-version: $resolved" "$workflow") = 1 ]]
grep -Fq "GO_VERSION: $resolved" "$workflow"
grep -Fq "go_version: $resolved" "$workflow"
# shellcheck disable=SC2016 # Match the workflow command literally.
grep -Fq 'version=$(bash scripts/go-version.sh)' "$workflow"
go_series=$(bash "$ROOT/scripts/go-series.sh")
grep -Fq "golang:$go_series-trixie " "$ROOT/Containerfile"
# The release checks its pins before using any test results or building its package.
release_go=$(awk '/^  go-version:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$workflow")
grep -Fxq '        run: bash scripts/plan-updates.sh --check' <<< "$release_go"
grep -Fxq '    needs: go-version' "$workflow"
grep -Fxq '    needs: [select-version, go-version]' "$workflow"
if grep -Eq 'apply-updates|update-candidate|report-updates|canary[.]yml|release-check[.]yml|compatibility/master[.]csv' "$workflow" "$gates"; then
    exit 1
fi
if grep -Eq 'apply-updates|plan-updates|resolve-updates|update-candidate|workflow_call|test-gates[.]yml|git push' "$canary"; then
    exit 1
fi
# shellcheck disable=SC2016 # Match the workflow command literally.
grep -Fxq '        run: bash scripts/plan-release-check.sh >> "$GITHUB_OUTPUT"' "$canary"
grep -Fq 'bash tests/ci/editor-gate.sh setup' "$canary"
grep -Fxq '        run: bash scripts/report-release-check.sh' "$canary"
# Each editor has its own job and passes its result as that job's output, so
# a rerun job that stops early leaves no result rather than an old one. Both
# jobs share one list of steps.
job() { awk -v job="  $1:" '$0 == job {found=1; next} found && /^  [[:alnum:]_-]+:/ {exit} found' "$canary"; }
for editor in code codium; do
    editor_job=$(job "release-check-$editor")
    grep -Fxq "      EDITOR_CLI: $editor" <<< "$editor_job"
    # shellcheck disable=SC2016 # Literal GitHub Actions expression.
    grep -Fxq '      outcome: ${{ steps.outcome.outputs.outcome }}' <<< "$editor_job"
    upper=${editor^^}
    grep -Fxq "          ${upper}_OUTCOME: \${{ needs.release-check-$editor.outputs.outcome }}" "$canary"
done
grep -Fxq '    steps: &release-check-steps' <<< "$(job release-check-code)"
grep -Fxq '    steps: *release-check-steps' <<< "$(job release-check-codium)"
grep -Fxq '    needs: [resolve, release-check-code, release-check-codium]' <<< "$(job report)"
grep -Fq "printf 'outcome=%s\n' \"\$outcome\" | tee -a \"\$GITHUB_OUTPUT\"" "$canary"
if grep -Eq 'download-artifact|editor-check-outcome|check_id|matrix' "$canary"; then exit 1; fi
[[ $(grep -c 'contents: write' "$canary") == 1 ]]
if grep -Fq 'contents: write' "$gates"; then exit 1; fi
awk -f "$ROOT/tests/lib/release-order.awk" "$workflow"
# shellcheck disable=SC2016 # Match the validator invocation literally.
grep -Fq 'bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$stage"' "$ROOT/scripts/build-tarball.sh"
grep -Fq 'git push origin ":refs/tags/' "$workflow"
# Scope assertions to the recorder jobs: unrelated success guards do not count.
release_record=$(awk '/^  record-compatibility:/{found=1;next} found && /^  [[:alnum:]_-]+:/{exit} found' "$workflow")
grep -Fxq '    needs: [select-version, publish]' <<< "$release_record"
# shellcheck disable=SC2016 # Checkout must survive deletion of the request tag.
grep -Fxq '          ref: ${{ github.sha }}' <<< "$release_record"
# shellcheck disable=SC2016 # Preserve the tested commit in release history.
grep -Fxq '          TESTED_COMMIT: ${{ github.sha }}' <<< "$release_record"
echo 'Release workflow contract passed'
