"""Release reuse must prove coverage and preserve failures across attempts."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_gates", ROOT / "scripts/lib/release-gates.py")
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)
REPO = "owner/project"
SHA = "a" * 40
URL = "https://github.com/owner/project/actions/runs/10/attempts/1"


class FakeAPI:
    def __init__(self, runs, proof):
        self.runs, self.evidence = runs, proof

    def collection(self, path, key):
        return copy.deepcopy(self.runs)

    def proof(self, run):
        return copy.deepcopy(self.evidence)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.runtime = dict(bash_version="5.2.21", podman_version="4.9.3",
                            tested_at="2026-10-08T01:00:00Z", run_url=URL)
        self.needs = {name: {"result": "success", "outputs": {}} for name in gates.GATES}
        self.needs["runtime"]["outputs"] = self.runtime
        self.env = dict(GATE_RESULTS=json.dumps(self.needs), GATE_INPUTS=json.dumps({"run_editor": True}),
                        GITHUB_REPOSITORY=REPO, GITHUB_SHA=SHA, GITHUB_RUN_ID="10",
                        GITHUB_RUN_ATTEMPT="1", GITHUB_SERVER_URL="https://github.com")
        self.proof = gates.record(self.env)
        self.run = dict(id=10, run_attempt=1, head_sha=SHA, head_branch="master", event="push",
                        path=".github/workflows/pr-checks.yml", repository={"full_name": REPO},
                        head_repository={"full_name": REPO}, status="completed", conclusion="success",
                        run_started_at="2026-10-08T00:00:00Z", updated_at="2026-10-08T02:00:00Z")

    def select(self, runs=None, proof=None):
        return gates.select(FakeAPI(runs if runs is not None else [self.run],
                                    proof if proof is not None else self.proof),
                            REPO, SHA, "master", 99, "https://github.com")

    def test_exact_success_preserves_metadata(self):
        self.assertEqual(self.select(), self.runtime)

    def test_record_requires_all_gates_and_pins(self):
        for gate in gates.GATES:
            for result in ("failure", "skipped", "cancelled"):
                needs = copy.deepcopy(self.needs)
                needs[gate]["result"] = result
                with self.assertRaises(ValueError):
                    gates.record(dict(self.env, GATE_RESULTS=json.dumps(needs)))
        for inputs in ({"run_editor": False}, {"run_editor": True, "code_version": "latest"}):
            with self.assertRaises(ValueError):
                gates.record(dict(self.env, GATE_INPUTS=json.dumps(inputs)))

    def test_rejects_wrong_commit_origin_branch_or_event(self):
        for change in ({"head_sha": "b" * 40}, {"head_branch": "other"}, {"event": "pull_request"},
                       {"path": ".github/workflows/canary.yml"},
                       {"head_repository": {"full_name": "fork/project"}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.select([dict(self.run, **change)])

    def test_rejects_missing_partial_stale_or_mismatched_proof(self):
        for key, value in (("sha", "b" * 40), ("schema", 2), ("repository", "fork/project"),
                           ("run_id", 9), ("attempt", 2),
                           ("gates", {"portable": "success"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.select(proof=dict(self.proof, **{key: value}))
        with self.assertRaises(ValueError):
            self.select(proof={})
        for field, value in (("bash_version", ""), ("podman_version", "x\nreuse=true"),
                             ("tested_at", "unknown"), ("run_url", URL.replace("/10/", "/11/"))):
            proof = copy.deepcopy(self.proof)
            proof["runtime"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.select(proof=proof)

    def test_later_failed_cancelled_skipped_or_active_runs_block(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", None):
            later = dict(self.run, id=11, path=".github/workflows/test-gates.yml",
                         conclusion=conclusion, updated_at="2026-10-08T03:00:00Z")
            with self.subTest(conclusion=conclusion), self.assertRaises(ValueError):
                self.select([later, self.run])
        # An old failed run rerun after the candidate also blocks reuse.
        earlier = dict(self.run, id=9, conclusion="failure", run_attempt=2,
                       run_started_at="2026-10-07T00:00:00Z", updated_at="2026-10-08T03:00:00Z")
        with self.assertRaises(ValueError):
            self.select([self.run, earlier])
        earlier["updated_at"] = "2026-10-07T02:00:00Z"
        self.assertEqual(self.select([earlier, self.run]), self.runtime)

    def test_current_release_is_excluded_and_newest_push_must_pass(self):
        current = dict(self.run, id=99, path=".github/workflows/release.yml", conclusion=None,
                       status="in_progress", updated_at="2026-10-08T03:00:00Z")
        self.assertEqual(self.select([current, self.run]), self.runtime)
        later = dict(self.run, id=11, conclusion="failure", run_started_at="2026-10-08T03:00:00Z")
        with self.assertRaises(ValueError):
            self.select([self.run, later])

    def test_failed_job_rerun_uses_current_attempt_proof(self):
        proof = gates.record(dict(self.env, GITHUB_RUN_ATTEMPT="2"))
        self.assertEqual(proof["runtime"]["run_url"], URL[:-1] + "2")
        rerun = dict(self.run, run_attempt=2)
        with self.assertRaises(ValueError):
            self.select([rerun])
        self.assertEqual(self.select([rerun], proof)["tested_at"], self.runtime["tested_at"])

    def test_api_pagination_and_incomplete_history(self):
        api = gates.GitHub(REPO)
        responses = [{"total_count": 101, "workflow_runs": list(range(100))},
                     {"total_count": 101, "workflow_runs": [100]}]
        with patch.object(api, "get", side_effect=responses) as get:
            self.assertEqual(len(api.collection("runs?head_sha=x", "workflow_runs")), 101)
            self.assertIn("&per_page=100&page=2", get.call_args.args[0])
        with patch.object(api, "get", return_value={"total_count": 1001}):
            with self.assertRaises(ValueError):
                api.collection("runs", "workflow_runs")

    def test_rerun_started_during_lookup_prevents_reuse(self):
        api = FakeAPI([self.run], self.proof)
        rerun = dict(self.run, run_attempt=2, status="in_progress", conclusion=None)
        with patch.object(api, "collection", side_effect=[[self.run], [rerun]]):
            with self.assertRaisesRegex(ValueError, "CI changed"):
                gates.select(api, REPO, SHA, "master", 99, "https://github.com")

    def test_artifact_attempt_expiry_and_zip_validation(self):
        api = gates.GitHub(REPO)
        artifact = dict(id=20, name="verified-test-gates-10-1", expired=False, size_in_bytes=1000)
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr(gates.PROOF_FILE, json.dumps(self.proof))
        with patch.object(api, "collection", return_value=[artifact]), patch.object(api, "get", return_value=archive.getvalue()):
            self.assertEqual(api.proof(self.run), self.proof)
        for artifacts in ([], [artifact, artifact], [dict(artifact, expired=True)],
                          [dict(artifact, name="verified-test-gates-10-2")]):
            with patch.object(api, "collection", return_value=artifacts), self.assertRaises(ValueError):
                api.proof(self.run)

    def test_lookup_failure_selects_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = dict(self.env, DEFAULT_BRANCH="master", GITHUB_OUTPUT=str(output))
            with patch.dict(os.environ, env), patch.object(sys, "argv", ["release-gates.py", "select"]), \
                    patch.object(gates.GitHub, "collection", side_effect=OSError("offline")):
                gates.main()
            self.assertEqual(output.read_text(), "reuse=false\n")

    def test_publish_condition_requires_verified_reuse_or_fresh_success(self):
        # Exercise the actual workflow condition with representative job results.
        # This checks the selected expressions, not GitHub's full workflow semantics.
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        publish = workflow.split("  publish:\n", 1)[1].split("    steps:\n", 1)[0]
        condition = re.search(r"    if: >-\n((?:      .*\n)+)", publish).group(1)
        condition = " ".join(condition.split()).replace("always()", "True")
        outputs = re.findall(r"^      (\w+): \$\{\{ (.+) \}\}$", publish, re.MULTILINE)
        self.assertEqual(len(outputs), 4)

        def evaluate(expression, context):
            expression = re.sub(r"needs\.[a-z._-]+", lambda match: repr(context[match[0]]), expression)
            return eval(expression.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}})

        for reuse, fresh, lookup, version, success in (
                ("true", "skipped", "success", "success", True),
                ("false", "success", "success", "success", True),
                ("false", "skipped", "success", "success", False),
                ("true", "failure", "success", "success", False),
                ("true", "skipped", "failure", "success", False),
                ("false", "cancelled", "success", "success", False),
                ("true", "skipped", "success", "failure", False),
                ("", "skipped", "success", "success", False)):
            context = {"needs.previous-gates.outputs.reuse": reuse, "needs.test-gates.result": fresh,
                       "needs.previous-gates.result": lookup, "needs.select-version.result": version}
            self.assertEqual(evaluate(condition, context), success)
            if success:
                fresh_names = {"bash_version": "runtime_bash_version", "podman_version": "runtime_podman_version",
                               "tested_at": "tested_at", "run_url": "test_run_url"}
                for name, expression in outputs:
                    context[f"needs.previous-gates.outputs.{name}"] = f"original-{name}"
                    context[f"needs.test-gates.outputs.{fresh_names[name]}"] = f"fresh-{name}"
                    expected = f"original-{name}" if reuse == "true" else f"fresh-{name}"
                    self.assertEqual(evaluate(expression, context), expected)
        self.assertNotIn("verified-gates", workflow)
        self.assertIn("needs.publish.outputs.run_url", workflow)

    def test_release_retry_cannot_hide_its_previous_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            env = dict(self.env, GITHUB_RUN_ATTEMPT="2", DEFAULT_BRANCH="master", GITHUB_OUTPUT=str(output))
            with patch.dict(os.environ, env), patch.object(sys, "argv", ["release-gates.py", "select"]), \
                    patch.object(gates.GitHub, "collection") as lookup:
                gates.main()
            lookup.assert_not_called()
            self.assertEqual(output.read_text(), "reuse=false\n")


if __name__ == "__main__":
    unittest.main()
