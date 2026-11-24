#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow=${1:-"$ROOT/.github/workflows/release.yml"}
canary=${2:-"$ROOT/.github/workflows/release-check.yml"}
gates=${3:-"$ROOT/.github/workflows/test-gates.yml"}
pr_checks="$ROOT/.github/workflows/pr-checks.yml"

job() { awk -v job="  $2:" '$0 == job {found=1; next} found && /^  [[:alnum:]_-]+:/ {exit} found' "$1"; }

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
# PR updates trigger fresh gates, and merging into master adds no second run.
pr_events=$(awk '/^on:/{found=1; next} found && /^[^[:space:]]/{exit} found && NF' "$pr_checks")
[[ "$pr_events" == '  pull_request:' ]]
pr_test_gates=$(job "$pr_checks" test-gates)
pr_result=$(job "$pr_checks" pr-gates)
grep -Fxq '    name: PR gates' <<< "$pr_result"
grep -Fxq '    needs: test-gates' <<< "$pr_result"
grep -Fxq '    if: always()' <<< "$pr_result"
# shellcheck disable=SC2016 # Match the workflow command literally.
grep -Fxq '        run: test "$GATES_RESULT" = success' <<< "$pr_result"

# Each release runs fresh gates. GitHub's default success condition requires
# all publication prerequisites to pass, including the full gates.
release_test_gates=$(job "$workflow" test-gates)
publish_job=$(job "$workflow" publish)
grep -Fxq '    needs: go-version' <<< "$release_test_gates"
grep -Fxq '    needs: [select-version, test-gates, package, install]' <<< "$publish_job"
if grep -Eq '^    if:' <<< "$release_test_gates"$'\n'"$publish_job"; then exit 1; fi
for caller in "$pr_test_gates" "$release_test_gates"; do
    grep -Fxq '    uses: ./.github/workflows/test-gates.yml' <<< "$caller"
    grep -Fxq '      run_editor: true' <<< "$caller"
    if grep -Fq 'lifecycle_jobs:' <<< "$caller"; then exit 1; fi
done

# ShellCheck runs once in its own gate; portable environments do not repeat it.
lint_job=$(job "$gates" lint)
grep -Fxq '        run: bash tests/run lint' <<< "$lint_job"
grep -Fq 'path: testlog/shellcheck-cache/success' <<< "$lint_job"
portable_job=$(job "$gates" portable)
if grep -Fq 'shellcheck-cache' <<< "$portable_job"; then exit 1; fi
if grep -Fq 'matrix-scope' "$gates" "$pr_checks"; then exit 1; fi
# shellcheck disable=SC2016 # Literal GitHub Actions expression.
grep -Fq 'JAILBOX_LIFECYCLE_SHARD: ${{ matrix.shard }}/8' "$gates"
grep -Fxq '        shard: [1, 2, 3, 4, 5, 6, 7, 8]' "$gates"
# Shards cannot see each other, so a later job checks coverage across all logs.
coverage_job=$(job "$gates" matrix-coverage)
grep -Fxq '    needs: matrix' <<< "$coverage_job"
if grep -Fq 'if:' <<< "$coverage_job"; then exit 1; fi
grep -Fxq '          pattern: matrix-logs-*' <<< "$coverage_job"
grep -Fxq '        run: bash tests/ci/check-matrix-coverage.sh 8 matrix-logs' <<< "$coverage_job"
grep -Fxq '            dist/install.sh' "$workflow"
for platform in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
    grep -Fxq "            platform: $platform" "$workflow"
done
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
grep -Fxq "      go_version: $resolved" <<< "$release_test_gates"
# shellcheck disable=SC2016 # Match the workflow command literally.
grep -Fq 'version=$(bash scripts/go-version.sh)' "$workflow"
go_series=$(bash "$ROOT/scripts/go-series.sh")
grep -Fq "golang:$go_series-trixie " "$ROOT/Containerfile"
# The release checks its pins before running gates or building its package.
release_go=$(job "$workflow" go-version)
grep -Fxq '        run: bash scripts/plan-updates.sh --check' <<< "$release_go"
grep -Fxq '    needs: [select-version, go-version]' <<< "$(job "$workflow" package)"
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
for editor in code codium; do
    editor_job=$(job "$canary" "release-check-$editor")
    grep -Fxq "      EDITOR_CLI: $editor" <<< "$editor_job"
    # shellcheck disable=SC2016 # Literal GitHub Actions expression.
    grep -Fxq '      outcome: ${{ steps.outcome.outputs.outcome }}' <<< "$editor_job"
    upper=${editor^^}
    grep -Fxq "          ${upper}_OUTCOME: \${{ needs.release-check-$editor.outputs.outcome }}" "$canary"
done
grep -Fxq '    steps: &release-check-steps' <<< "$(job "$canary" release-check-code)"
grep -Fxq '    steps: *release-check-steps' <<< "$(job "$canary" release-check-codium)"
grep -Fxq '    needs: [resolve, release-check-code, release-check-codium]' <<< "$(job "$canary" report)"
grep -Fq "printf 'outcome=%s\n' \"\$outcome\" | tee -a \"\$GITHUB_OUTPUT\"" "$canary"
if grep -Eq 'download-artifact|editor-check-outcome|check_id|matrix' "$canary"; then exit 1; fi
[[ $(grep -c 'contents: write' "$canary") == 1 ]]
if grep -Fq 'contents: write' "$gates"; then exit 1; fi
awk -f "$ROOT/tests/lib/release-order.awk" "$workflow"
# shellcheck disable=SC2016 # Match the validator invocation literally.
grep -Fq 'bash "$ROOT_DIR/scripts/validate-release.sh" "$version" "$stage"' "$ROOT/scripts/build-tarball.sh"
grep -Fq 'git push origin ":refs/tags/' "$workflow"
# Scope assertions to the recorder jobs: unrelated success guards do not count.
release_record=$(job "$workflow" record-compatibility)
grep -Fxq '    needs: [select-version, publish]' <<< "$release_record"
# shellcheck disable=SC2016 # Match the output expressions literally.
for binding in 'bash_version: ${{ needs.test-gates.outputs.runtime_bash_version }}' \
    'podman_version: ${{ needs.test-gates.outputs.runtime_podman_version }}' \
    'tested_at: ${{ needs.test-gates.outputs.tested_at }}' \
    'run_url: ${{ needs.test-gates.outputs.test_run_url }}'; do
    grep -Fxq "      $binding" <<< "$publish_job"
done
# shellcheck disable=SC2016 # Checkout must survive deletion of the request tag.
grep -Fxq '          ref: ${{ github.sha }}' <<< "$release_record"
# shellcheck disable=SC2016 # Preserve the tested commit in release history.
grep -Fxq '          TESTED_COMMIT: ${{ github.sha }}' <<< "$release_record"
echo 'Release workflow contract passed'
