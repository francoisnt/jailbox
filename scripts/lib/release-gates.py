#!/usr/bin/env python3
"""Record full pinned gate results; conservatively select evidence for releases."""
import datetime as dt
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import zipfile

GATES = {"portable", "runtime", "matrix", "editor"}
WORKFLOWS = {"pr-checks.yml", "test-gates.yml", "release.yml", "canary.yml"}
PROOF_FILE = "verified-test-gates.json"
RUNTIME_FIELDS = ("bash_version", "podman_version", "tested_at", "run_url")


def timestamp(value):
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def runtime_metadata(value, expected_url):
    result = {key: value[key] for key in RUNTIME_FIELDS}
    for key in ("bash_version", "podman_version"):
        if not isinstance(result[key], str) or not re.fullmatch(r"[a-zA-Z0-9_.:+/-]+", result[key]):
            raise ValueError("missing or invalid runtime version")
    timestamp(result["tested_at"])
    base, attempt = expected_url.rsplit("/", 1)
    actual_base, actual_attempt = result["run_url"].rsplit("/", 1)
    if actual_base != base or not 1 <= int(actual_attempt) <= int(attempt):
        raise ValueError("runtime evidence belongs to another attempt")
    # Failed-job reruns retain successful prerequisites from earlier attempts.
    # Attribute complete coverage to the successful attempt, keeping the actual
    # runtime sample's timestamp and versions.
    result["run_url"] = expected_url
    return result


def run_url(server, repository, run_id, attempt):
    return f"{server}/{repository}/actions/runs/{run_id}/attempts/{attempt}"


def record(env):
    needs = json.loads(env["GATE_RESULTS"])
    inputs = json.loads(env["GATE_INPUTS"])
    if set(needs) != GATES or any(needs[gate]["result"] != "success" for gate in GATES):
        raise ValueError("all four gates must pass")
    if inputs.pop("run_editor", None) is not True or any(inputs.values()):
        raise ValueError("evidence requires both editors and the pinned dependencies")
    identity = {"repository": env["GITHUB_REPOSITORY"], "sha": env["GITHUB_SHA"],
                "run_id": int(env["GITHUB_RUN_ID"]), "attempt": int(env["GITHUB_RUN_ATTEMPT"])}
    url = run_url(env["GITHUB_SERVER_URL"], identity["repository"], identity["run_id"], identity["attempt"])
    return {"schema": 1, **identity,
            "gates": {gate: "success" for gate in sorted(GATES)},
            "runtime": runtime_metadata(needs["runtime"]["outputs"], url)}


class GitHub:
    def __init__(self, repository):
        self.base = f"repos/{repository}/actions"

    def get(self, path, binary=False):
        response = subprocess.run(
            ["gh", "api", f"{self.base}/{path}", "-H", "X-GitHub-Api-Version: 2022-11-28"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        return response.stdout if binary else json.loads(response.stdout)

    def collection(self, path, key):
        result = []
        separator = "&" if "?" in path else "?"
        for page in range(1, 11):
            data = self.get(f"{path}{separator}per_page=100&page={page}")
            if data["total_count"] > 1000:
                raise ValueError("too many results to establish complete history")
            result.extend(data[key])
            if len(result) == data["total_count"]:
                return result
            if not data[key]:
                break
        raise ValueError("incomplete Actions history")

    def proof(self, run):
        name = f"verified-test-gates-{run['id']}-{run['run_attempt']}"
        artifacts = self.collection(f"runs/{run['id']}/artifacts", "artifacts")
        matches = [item for item in artifacts if item["name"] == name and not item["expired"]]
        if len(matches) != 1 or not 0 < matches[0]["size_in_bytes"] <= 65536:
            raise ValueError("verified gate artifact missing, expired or ambiguous")
        archive = self.get(f"artifacts/{matches[0]['id']}/zip", binary=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            if zipped.namelist() != [PROOF_FILE] or zipped.getinfo(PROOF_FILE).file_size > 65536:
                raise ValueError("unexpected gate artifact contents")
            return json.loads(zipped.read(PROOF_FILE))


def workflow(run):
    return run["path"].split("@", 1)[0].removeprefix(".github/workflows/")


def select(api, repository, sha, branch, current_run, server):
    def history():
        runs = api.collection(f"runs?head_sha={urllib.parse.quote(sha)}", "workflow_runs")
        return [run for run in runs if run["id"] != current_run and run["head_sha"] == sha
                and run["repository"]["full_name"] == repository and workflow(run) in WORKFLOWS]

    def snapshot(runs):
        return sorted((run["id"], run["run_attempt"], run["status"], run["conclusion"], run["updated_at"])
                      for run in runs)

    relevant = history()
    # Push checks cannot carry canary overrides or PR merge-checkout ambiguity.
    candidates = [run for run in relevant if workflow(run) == "pr-checks.yml"
                  and run["event"] == "push" and run["head_branch"] == branch
                  and run["head_repository"]["full_name"] == repository]
    if not candidates:
        raise ValueError("no push CI result for this exact commit")
    candidate = max(candidates, key=lambda run: timestamp(run["run_started_at"]))
    if candidate["status"] != "completed" or candidate["conclusion"] != "success":
        raise ValueError("latest push CI has not passed")
    started = timestamp(candidate["run_started_at"])
    for run in relevant:
        # Conservatively include canaries and partial/manual runs as blockers.
        # A successful later canary cannot erase a failed pinned check.
        if (run["id"] != candidate["id"] and timestamp(run["updated_at"]) >= started
                and (run["status"] != "completed" or run["conclusion"] != "success")):
            raise ValueError("a later test run is unfinished or did not pass")
    proof = api.proof(candidate)
    expected = {"schema": 1, "repository": repository, "sha": sha,
                "run_id": candidate["id"], "attempt": candidate["run_attempt"],
                "gates": {gate: "success" for gate in GATES}}
    if any(proof.get(key) != value for key, value in expected.items()):
        raise ValueError("gate evidence does not match this commit, attempt or coverage")
    url = run_url(server, repository, candidate["id"], candidate["run_attempt"])
    metadata = runtime_metadata(proof["runtime"], url)
    if snapshot(history()) != snapshot(relevant):
        raise ValueError("CI changed while checking the evidence")
    return metadata


def main():
    if sys.argv[1:] == ["record"]:
        Path(PROOF_FILE).write_text(json.dumps(record(os.environ), sort_keys=True) + "\n")
        return
    if sys.argv[1:] != ["select"]:
        raise SystemExit("usage: release-gates.py record|select")
    outputs = {"reuse": "false"}
    try:
        # The current run is excluded from history while it is in progress.
        # On retries, do not thereby hide its own earlier failed test attempt.
        if int(os.environ["GITHUB_RUN_ATTEMPT"]) != 1:
            raise ValueError("release retries require fresh gates")
        metadata = select(GitHub(os.environ["GITHUB_REPOSITORY"]),
                          os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"],
                          os.environ["DEFAULT_BRANCH"], int(os.environ["GITHUB_RUN_ID"]),
                          os.environ["GITHUB_SERVER_URL"])
        outputs.update(metadata, reuse="true")
        print(f"Reusing complete passing CI: {metadata['run_url']}")
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError,
            zipfile.BadZipFile) as error:
        # Missing permissions, expired artifacts and uncertain evidence all
        # choose fresh gates. Never turn lookup failure into permission to skip.
        print(f"Running fresh release gates: {error}")
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        for key, value in outputs.items():
            stream.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
