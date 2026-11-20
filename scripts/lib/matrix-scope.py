#!/usr/bin/env python3
"""Decide whether PR checks may skip the lifecycle matrix.

The matrix is skipped only when every file changed since the newest verified
full pass on an ancestor commit is on the safe list below. Anything else,
including a lookup failure, runs the full matrix.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.parse
import zipfile

spec = importlib.util.spec_from_file_location("release_gates", Path(__file__).with_name("release-gates.py"))
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)

# Paths the matrix gate never reads. Keep this list narrow: an unlisted path
# only costs a full run, while a wrong entry can skip needed coverage.
SAFE_PREFIXES = (
    "docs/", "plans/", "compatibility/", ".vscode/",
    "tests/unit/", "tests/harness/", "tests/portable/",
    "tests/lib/editor/", "tests/fixtures/editor-smoke/", "tests/e2e/fixtures/",
)
SAFE_FILES = frozenset((
    "README.md", "ARCHITECTURE.md", "CONTRIBUTING.md", "AGENTS.md", "CLAUDE.md", "LICENSE",
    ".gitignore", ".github/dependabot.yml", "src/install.sh",
    "tests/e2e/editor-smoke.sh", "tests/e2e/editor-validate.sh",
    "tests/core-verification.md", "tests/frontend-verification.md",
    "tests/ci/setup-macos.sh", "tests/ci/setup-portable.sh",
))
# GitHub's comparison lists at most 300 files; a full list may be truncated.
MAX_FILES = 300
RECENT_RUNS = 20


def matrix_relevant(path):
    return path not in SAFE_FILES and not path.startswith(SAFE_PREFIXES)


class GitHub(gates.GitHub):
    def __init__(self, repository):
        super().__init__(repository)
        self.repository = repository

    def repo(self, path):
        response = subprocess.run(
            ["gh", "api", f"repos/{self.repository}/{path}", "-H", "X-GitHub-Api-Version: 2022-11-28"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        return json.loads(response.stdout)

    def verified_runs(self, branch):
        query = urllib.parse.urlencode({"branch": branch, "event": "push", "status": "success",
                                        "per_page": RECENT_RUNS})
        return self.get(f"workflows/pr-checks.yml/runs?{query}")["workflow_runs"]

    def compare(self, base, head):
        return self.repo(f"compare/{base}...{head}")

    def evidence(self, run):
        """Return a run's gate evidence, or None when it has none to offer."""
        name = f"verified-test-gates-{run['id']}-{run['run_attempt']}"
        artifacts = self.collection(f"runs/{run['id']}/artifacts", "artifacts")
        if not any(item["name"] == name and not item["expired"] for item in artifacts):
            return None  # The matrix was skipped, or the evidence expired.
        return self.proof(run)  # Unreadable or ambiguous evidence is a lookup failure.


def baseline(api, repository, branch, head):
    """Return (base sha, comparison) for the newest verified full-pass ancestor."""
    runs = sorted(api.verified_runs(branch), key=lambda run: gates.timestamp(run["run_started_at"]),
                  reverse=True)
    for run in runs:
        if (run["head_branch"] != branch or run["repository"]["full_name"] != repository
                or gates.workflow(run) != "pr-checks.yml"):
            continue
        proof = api.evidence(run)
        if proof is None:
            continue
        expected = {"schema": 1, "repository": repository, "sha": run["head_sha"],
                    "gates": {gate: "success" for gate in gates.GATES}}
        if not isinstance(proof, dict) or any(proof.get(key) != value for key, value in expected.items()):
            raise ValueError(f"gate evidence for run {run['id']} does not match its commit or coverage")
        comparison = api.compare(run["head_sha"], head)
        if comparison["status"] in ("ahead", "identical"):
            return run["head_sha"], comparison
    raise ValueError("no verified full pass on an ancestor commit")


def decide(api, repository, branch, head):
    """Return (run matrix, explanation)."""
    base, comparison = baseline(api, repository, branch, head)
    files = comparison["files"]
    if len(files) >= MAX_FILES:
        return True, f"{len(files)} files changed since {base}; the list may be incomplete"
    paths = sorted({path for item in files for path in (item["filename"], item.get("previous_filename"))
                    if path})
    relevant = [path for path in paths if matrix_relevant(path)]
    if relevant:
        shown = ", ".join(relevant[:10]) + (" ..." if len(relevant) > 10 else "")
        return True, f"matrix-relevant changes since {base}: {shown}"
    return False, f"no matrix-relevant changes since verified full pass {base}"


def main():
    if sys.argv[1:]:
        raise SystemExit("usage: matrix-scope.py")
    run, reason = True, "full matrix requested"
    if os.environ.get("MATRIX_CHANGE_SCOPE") == "true":
        try:
            repository = os.environ["GITHUB_REPOSITORY"]
            run, reason = decide(GitHub(repository), repository, os.environ["DEFAULT_BRANCH"],
                                 os.environ["GITHUB_SHA"])
        except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
                zipfile.BadZipFile) as error:
            # Never turn an uncertain lookup into permission to skip coverage.
            run, reason = True, f"running the full matrix: {error}"
    print(f"Lifecycle matrix: {'run' if run else 'skip'} ({reason})")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"run={'true' if run else 'false'}\n")


if __name__ == "__main__":
    main()
