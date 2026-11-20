"""PR checks may skip the matrix only for proven, matrix-irrelevant changes."""
import copy
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("matrix_scope", ROOT / "scripts/lib/matrix-scope.py")
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
REPO = "owner/project"
HEAD = "f" * 40


def run(number, sha):
    return dict(id=number, run_attempt=1, head_sha=sha, head_branch="master", event="push",
                path=".github/workflows/pr-checks.yml", repository={"full_name": REPO},
                run_started_at=f"2026-10-{number:02d}T00:00:00Z")


def proof(sha):
    return {"schema": 1, "repository": REPO, "sha": sha, "run_id": 1, "attempt": 1,
            "gates": {gate: "success" for gate in scope.gates.GATES}}


class FakeAPI:
    def __init__(self, runs, proofs, comparisons):
        self.runs, self.proofs, self.comparisons = runs, proofs, comparisons

    def verified_runs(self, branch):
        return copy.deepcopy(self.runs)

    def evidence(self, item):
        value = self.proofs.get(item["head_sha"])
        if isinstance(value, Exception):
            raise value
        return copy.deepcopy(value)

    def compare(self, base, head):
        return copy.deepcopy(self.comparisons[base])


def changed(*paths, status="ahead"):
    return {"status": status, "files": [{"filename": path} for path in paths]}


class ScopeTests(unittest.TestCase):
    def decide(self, runs, proofs, comparisons):
        return scope.decide(FakeAPI(runs, proofs, comparisons), REPO, "master", HEAD)

    def test_safe_list_excludes_every_matrix_input(self):
        for path in ("docs/security.md", "plans/archive/x.md", "README.md", "CLAUDE.md",
                     "compatibility/master.csv", "tests/unit/exec.sh", "tests/harness/parallel/lifecycle-pool.sh",
                     "tests/e2e/editor-smoke.sh", ".github/dependabot.yml"):
            self.assertFalse(scope.matrix_relevant(path), path)
        for path in ("src/jailbox", "src/host/frontend/editor.sh", "src/public-api.sh", "versions.env",
                     ".github/workflows/test-gates.yml", "tests/run", "Containerfile", "docs",
                     "scripts/lib/matrix-scope.py", "tests/lib/lifecycle-jobs.sh", "new-file"):
            self.assertTrue(scope.matrix_relevant(path), path)
        # Files the matrix gate executes or reads must never be skippable.
        inputs = ["src", "scripts/lib", ".github/workflows", "tests/integration", "tests/ci/setup-linux.sh",
                  "tests/ci/setup-common.sh", "tests/run", "versions.env"]
        inputs += [str(path.relative_to(ROOT)) for path in (ROOT / "tests/lib").glob("lifecycle*")]
        inputs += [str(path.relative_to(ROOT)) for path in (ROOT / "tests/fixtures").glob("lifecycle*")]
        checked = 0
        for name in inputs:
            target = ROOT / name
            for path in [target] if target.is_file() else target.rglob("*"):
                relative = str(path.relative_to(ROOT))
                if path.is_file() and relative != "src/install.sh":
                    self.assertTrue(scope.matrix_relevant(relative), relative)
                    checked += 1
        self.assertGreater(checked, 100)

    def test_skips_only_when_every_change_is_safe(self):
        runs = [run(2, "b" * 40)]
        proofs = {"b" * 40: proof("b" * 40)}
        self.assertEqual(self.decide(runs, proofs, {"b" * 40: changed("docs/a.md", "plans/p.md")})[0], False)
        self.assertEqual(self.decide(runs, proofs, {"b" * 40: changed(status="identical")})[0], False)
        run_matrix, reason = self.decide(runs, proofs, {"b" * 40: changed("docs/a.md", "src/jailbox")})
        self.assertTrue(run_matrix)
        self.assertIn("src/jailbox", reason)
        moved = {"status": "ahead", "files": [{"filename": "docs/moved.sh", "previous_filename": "src/x.sh"}]}
        self.assertTrue(self.decide(runs, proofs, {"b" * 40: moved})[0])
        many = changed(*[f"docs/{index}.md" for index in range(scope.MAX_FILES)])
        self.assertTrue(self.decide(runs, proofs, {"b" * 40: many})[0])

    def test_baseline_is_the_newest_verified_ancestor(self):
        older, middle, newest = "a" * 40, "b" * 40, "c" * 40
        runs = [run(1, older), run(3, newest), run(2, middle)]
        comparisons = {older: changed("docs/a.md"), middle: changed("src/jailbox"),
                       newest: changed("docs/a.md", status="diverged")}
        # The newest run is not an ancestor, so the middle run is the baseline.
        proofs = {sha: proof(sha) for sha in (older, middle, newest)}
        self.assertTrue(self.decide(runs, proofs, comparisons)[0])
        # A run without evidence (skipped matrix or expired) is passed over.
        del proofs[middle]
        self.assertEqual(self.decide(runs, proofs, comparisons)[0], False)
        # Unreadable or mismatched evidence is a lookup failure, never a fallback.
        for broken in (ValueError("unexpected gate artifact contents"), dict(proof(middle), sha=older),
                       dict(proof(middle), gates={})):
            proofs[middle] = broken
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                self.decide(runs, proofs, comparisons)
        del proofs[middle]
        del proofs[older]
        with self.assertRaisesRegex(ValueError, "no verified full pass"):
            self.decide(runs, proofs, comparisons)
        other = dict(run(4, older), head_branch="feature")
        with self.assertRaisesRegex(ValueError, "no verified full pass"):
            self.decide([other], {older: proof(older)}, comparisons)

    def main(self, env, decide=None):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = dict(env, GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY=REPO, GITHUB_SHA=HEAD,
                       DEFAULT_BRANCH="master")
            with patch.dict(os.environ, env, clear=True), patch.object(sys, "argv", ["matrix-scope.py"]), \
                    patch.object(scope, "decide", side_effect=decide or AssertionError("unexpected lookup")):
                scope.main()
            return output.read_text()

    def test_only_a_missing_artifact_passes_a_run_over(self):
        item = run(5, "e" * 40)
        name = f"verified-test-gates-{item['id']}-{item['run_attempt']}"
        api = scope.GitHub(REPO)
        for artifacts, expected in (([], None), ([{"name": name, "expired": True}], None),
                                    ([{"name": "other", "expired": False}], None)):
            with patch.object(api, "collection", return_value=artifacts), \
                    patch.object(api, "proof", side_effect=AssertionError("unexpected download")):
                self.assertIs(api.evidence(item), expected)
        with patch.object(api, "collection", return_value=[{"name": name, "expired": False}]), \
                patch.object(api, "proof", side_effect=ValueError("unexpected gate artifact contents")), \
                self.assertRaises(ValueError):
            api.evidence(item)

    def test_main_runs_full_matrix_unless_a_skip_is_proven(self):
        self.assertEqual(self.main({}), "run=true\n")
        self.assertEqual(self.main({"MATRIX_CHANGE_SCOPE": "false"}), "run=true\n")
        self.assertEqual(self.main({"MATRIX_CHANGE_SCOPE": "true"}, OSError("offline")), "run=true\n")
        self.assertEqual(self.main({"MATRIX_CHANGE_SCOPE": "true"}, ValueError("no baseline")), "run=true\n")
        self.assertEqual(self.main({"MATRIX_CHANGE_SCOPE": "true"}, lambda *args: (False, "docs only")),
                         "run=false\n")


if __name__ == "__main__":
    unittest.main(verbosity=0)
