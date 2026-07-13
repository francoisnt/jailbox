# Version-pinning policy: versions.env, pinned CI, canary, run metadata, generated README matrix

## Context

The Alpine/VSCodium editor smoke test broke because open-remote-ssh 0.2.0 silently updated (its `flock -x -w 30` is rejected by BusyBox flock), while the pinned headless REH probe kept passing. Root cause: three unsynchronized version regimes — the GUI smoke test floats silently, the REH probe is pinned, and CI installs latest editors while the README claims a deterministic gate. The agreed policy: pin everything jailbox chooses, canary-test everything upstream chooses, auto-advance pins on canary green, and make `versions.env` the single source of truth whose history records what each commit was verified against.

## Execution environment (added 2026-07-13 — read first)

The implementing session runs **inside a jailbox dev container** (user `jailbox`, project at `/home/jailbox/project`), not on the host. Probe capabilities at session start before trusting the Verification section:
- **podman is likely unavailable in-container** — integration/e2e verification (`tests/run --core-tests`, `--editor-smoke`, `wrapper-images.sh`) probably cannot run locally. Verify via CI instead (push a branch, use the release-gate `workflow_dispatch`) or hand the run to the user on the host.
- **Egress may be limited to the downloader-proxy allowlist** — the network calls in `resolve-latest-versions.sh` (GitHub API, update.code.visualstudio.com, marketplace, open-vsx) and "resolve initial pin values at landing time" may fail in-container. If so, get values from a CI run or ask the user to run the resolver on the host.
- Should work in-container: all file edits, `scripts/lint.sh` (if shellcheck is installed), `tests/run --unit-tests`, git commits. Check `git remote -v` and push access before assuming CI-based verification is reachable.
- Untracked-file context: this file (`docs/version-pinning-plan.md`) is the canonical plan; the untracked `Containerfile`, `.env`, `.vscode/` at repo root predate the plan — don't fold any of them into implementation commits.

## Assessment of the discussion doc vs. repo (verified)

Accurate: REH pin lives inline at [tests/e2e/headless.sh:163-164](tests/e2e/headless.sh#L163-L164); smoke test never records editor versions; CI installs latest editors + unpinned extensions ([tests/ci/setup-linux.sh:31-48](tests/ci/setup-linux.sh#L31-L48)); no canary, no automation, no metadata; README:217 claim is false today.

Corrections baked into this plan:
- **Heavy CI jobs already pin `ubuntu-24.04`** — only pr-checks + portable-smoke use `ubuntu-latest`. Fix those; drop `CI_RUNNER_IMAGE` from versions.env (an env file can't drive `runs-on:` anyway).
- **README matrix is not version-less** — OS versions are there; it's editor/extension/REH versions that are missing.
- **Don't duplicate CODIUM_* and REH_* keys** — same upstream artifact set; keep one pair (`CODIUM_VERSION`/`CODIUM_COMMIT`) and derive the REH from it.
- **Also pin `ms-vscode-remote.remote-ssh`** — the VS Code path floats exactly like open-remote-ssh does.
- **Keep base images pinned by tag, not digest** (the doc's own principle: the tag is the meaningful pin); record resolved digests per-run in meta.env instead.
- **`tests/ci/setup-macos.sh` is dead in CI** — macOS container jobs were removed in 999d314 because GitHub macOS runners lack the hypervisor entitlement (podman machine can't start). Keep the script, keep it floating, document it as the manual local-Mac path.

## Decisions (user-confirmed)

1. **Pin bump = direct push to master, no PR.** The canary run *is* the gate-equivalent validation. Guard: push the bump commit only if `origin/master` still equals the SHA the canary tested (fast-forward guard); if master moved, skip — next run retests. Needs only `contents: write` on the default `GITHUB_TOKEN`; no PAT, no repo-settings changes.
2. **Release gate stays pinned-only** (no advisory latest job); the canary owns the latest signal.
3. **setup-macos.sh: keep, floating, documented** (see above).

## Step 1 — `versions.env` + consumers source it (pure refactor, values unchanged)

New file `versions.env` at repo root, `KEY="value"` per line (canary rewrites it with sed):

```bash
# Single source of truth for external version pins. See README "Tested Configurations".
# Consumers honor JAILBOX_* env overrides over these values.
# VSCodium desktop + REH server are one artifact set — one pin.
CODIUM_VERSION="1.116.02821"
CODIUM_COMMIT="221e0a382c0be3a673a4e4cab0601344a0b3de3a"   # embedded VS Code commit; names the REH server dir
CODE_VERSION="<latest-at-landing>"
REMOTE_SSH_VERSION="<latest-at-landing>"        # ms-vscode-remote.remote-ssh (VS Code)
OPEN_REMOTE_SSH_VERSION="<latest-at-landing>"   # jeanp413.open-remote-ssh (VSCodium, open-vsx)
BASE_IMAGE_DEBIAN="debian:12"
BASE_IMAGE_ALPINE="alpine:3.21"    # container/tinyproxy/Containerfile must match (checked in Step 5)
BASE_IMAGE_FEDORA="fedora:41"
PINS_LAST_VERIFIED="<date>"        # updated by canary bump
```

- [tests/e2e/headless.sh](tests/e2e/headless.sh): source versions.env; defaults become `${JAILBOX_E2E_REH_RELEASE:-$CODIUM_VERSION}` / `${JAILBOX_E2E_REH_COMMIT:-$CODIUM_COMMIT}`; update header docs.
- [tests/integration/dev-images.Containerfile](tests/integration/dev-images.Containerfile): global `ARG BASE_IMAGE_*` (defaults = current tags) before first FROM; all three `debian:12` stages use `${BASE_IMAGE_DEBIAN}`.
- [tests/integration/wrapper-images.sh](tests/integration/wrapper-images.sh): source versions.env; pass `--build-arg BASE_IMAGE_*` to the dev-images build.
- `container/tinyproxy/Containerfile`: unchanged (built at runtime by jailbox itself); extend its "intentionally pinned" comment to reference versions.env.

## Step 2 — Pin CI installs (the gate becomes what the README claims)

- [tests/ci/setup-linux.sh](tests/ci/setup-linux.sh): source versions.env, apply `JAILBOX_*` overrides (the canary's injection surface), then:
  - VS Code: `https://update.code.visualstudio.com/${CODE_VERSION}/linux-deb-x64/stable`; `code --install-extension ms-vscode-remote.remote-ssh@${REMOTE_SSH_VERSION} --force`.
  - VSCodium: drop the apt repo entirely (only serves latest); install `codium_${CODIUM_VERSION}_amd64.deb` from GitHub releases (verify asset name against a real release); install open-remote-ssh from the deterministic open-vsx VSIX URL `https://open-vsx.org/api/jeanp413/open-remote-ssh/${VER}/file/jeanp413.open-remote-ssh-${VER}.vsix` (avoids gallery `@version` negotiation flakiness).
- [tests/ci/setup-common.sh](tests/ci/setup-common.sh): verifiers assert the pinned versions (`code --version | head -1` == `$CODE_VERSION`; `--list-extensions --show-versions` contains `id@version`; confirm codium's exact `--version` line format during implementation).
- [tests/ci/setup-macos.sh](tests/ci/setup-macos.sh): header comment only — manual local-Mac convenience, intentionally floating, CI can't run it (no hypervisor entitlement on GH macOS runners, see 999d314).
- [.github/workflows/pr-checks.yml](.github/workflows/pr-checks.yml) + [release-gate.yml](.github/workflows/release-gate.yml): `ubuntu-latest` → `ubuntu-24.04` (keep `macos-latest`, portable smoke only).
- README:217: hand-fix wording now ("pinned to the versions in versions.env"); full generation in Step 5.

## Step 3 — Run metadata: `meta.env` in every testlog dir

New sourced helper `tests/lib/run-meta.sh` (new dir; follows the `source "$JAILBOX_DIR/..."` + `# shellcheck source=` convention). All fields best-effort — metadata must never fail a run:
- `write_run_meta <dir>`: UTC date, jailbox git SHA + dirty flag, host uname/os-release, podman version.
- `run_meta_editor <dir> <bin>`: editor binary, version + commit (lines 1-2 of `--version`), remote-ssh/open-remote-ssh extension id@version from `--list-extensions --show-versions`.
- `run_meta_reh <dir> <release> <commit>`: release, commit, derived download URL.
- `run_meta_image <dir> <stage> <ref>`: image ref, resolved digest (`podman image inspect --format '{{index .RepoDigests 0}}'`), container `PRETTY_NAME` via `podman run --rm <ref> cat /etc/os-release`.

Wire into the three run-dir creators: [tests/e2e/editor-smoke.sh:101-105](tests/e2e/editor-smoke.sh#L101-L105), [tests/e2e/headless.sh:546](tests/e2e/headless.sh#L546) (hoist REH release/commit resolution to file scope so probe + metadata share it), [tests/integration/wrapper-images.sh:369](tests/integration/wrapper-images.sh#L369). Add to `scripts/lint.sh` list. Gate already uploads `testlog/*` artifacts, so meta.env ships in CI for free.

## Step 4 — Canary workflow + auto-bump

New `scripts/resolve-latest-versions.sh` (add to lint.sh): prints `KEY=value` for `$GITHUB_OUTPUT`; resolves VSCodium latest (GitHub API), VS Code latest (`update.code.visualstudio.com/api/update/linux-x64/stable/latest` → `.productVersion`), remote-ssh latest (marketplace extensionquery POST), open-remote-ssh latest (open-vsx API); compares to versions.env; emits `has_new`. Latest CODIUM_COMMIT is read post-install in the test job (`codium --version | sed -n 2p`), not resolved here.

New `.github/workflows/canary.yml`:
- Triggers: daily cron + `workflow_dispatch` (with `force` input). Daily check that exits early when nothing is new ≈ "per upstream release"; subsumes the weekly requirement. `permissions: contents: write, issues: write`; `concurrency: canary`.
- Jobs: `resolve` → (if has_new) **full gate-equivalent suite at latest versions**, reusing existing scripts with `JAILBOX_*` version overrides: `editor-smoke-latest` (matrix code/codium, `setup-linux.sh --with-editors`, wrapper-images, `tests/run --editor-smoke`, upload testlogs) and `core-tests-latest` (`tests/run --core-tests` with `JAILBOX_E2E_REH_RELEASE/COMMIT` = latest). Full-suite parity is required for the auto-pin to be a sound "verified" claim.
- `report` job (`if: always() && has_new`), logic in `scripts/canary-report.sh`:
  - **On any failure**: file a deduped issue (search open issues for the version-set key in the title before creating; label `canary`; note Alpine/VSCodium best-effort tier). Dedup-by-version = per-version tracking; a re-run after transient flake goes green and bumps normally.
  - **On success**: sed the new versions + `PINS_LAST_VERIFIED` into versions.env, run the README generator (Step 5), commit, and **push directly to master only if `origin/master` still equals the tested SHA**; otherwise skip (next run retests). Close any open canary issue for that version set.
- No PAT, no repo-settings changes needed.

## Step 5 — Generated README "Tested Configurations"

New `scripts/gen-tested-matrix.sh` (add to lint.sh):
- default: print block; `--write`: replace between `<!-- BEGIN GENERATED: tested-matrix -->` / `<!-- END -->` markers in README.md; `--check`: fail if regeneration differs, **plus** consistency checks (tinyproxy FROM == `BASE_IMAGE_ALPINE`; dev-images.Containerfile ARG defaults == versions.env).
- Block content: one-paragraph policy statement (gate = pinned versions in versions.env; every upstream release canary-tested; pin auto-advances on green; Alpine/VSCodium best-effort — pinned combo release-blocking, latest failures tracked as issues); the OS × editor table with concrete versions; extension + REH versions; `Last verified: $PINS_LAST_VERIFIED`.
- README.md:215-225 replaced by markers + generated content (kills the false claim).
- pr-checks.yml: add `bash scripts/gen-tested-matrix.sh --check` to the shellcheck job.

## Sequencing (each step lands independently)

1. versions.env + refactors (no behavior change)
2. Pinned CI installs + runner pins + README wording fix
3. run-meta.sh + wiring
4. resolve-latest-versions.sh + canary.yml + canary-report.sh
5. gen-tested-matrix.sh + README markers + `--check` in pr-checks

## Handoff notes for the implementing session (verified this session — don't re-derive)

**Decision history (user-confirmed, don't re-ask):** direct push to master for pin bumps was the *user's* choice over the doc's PR approach (soundness restored via the fast-forward guard); pinned-only gate confirmed; setup-macos.sh stays floating — macOS container CI was removed in 999d314 because GitHub macOS runners lack the hypervisor entitlement (podman machine fails on applehv/libkrun/qemu), not by policy, so the script is the only macOS container-test path and is manual-only.

**Repo conventions:**
- `scripts/lint.sh` enumerates scripts explicitly — every new .sh file must be added to its list or it goes unlinted (setup-macos.sh is at lint.sh:25 as an example).
- Sourcing pattern: `# shellcheck source=<repo-relative>` directive + `source "$JAILBOX_DIR/..."` (see headless.sh:18-19); CI setup scripts compute `ROOT_DIR` and source `setup-common.sh` (setup-linux.sh:5-9).
- Env override convention: `JAILBOX_*` with `${VAR:-default}`.
- Orchestrator: `tests/run` with `--unit-tests` / `--core-tests` (unit+integration+headless) / `--editor-smoke`. No Makefile.
- `release.yml` invokes `release-gate.yml` via `workflow_call`, so gate changes automatically apply to releases. Releases dispatch via a pushed `release-request` tag (scripts/release.sh:262-269).

**Exact anchors (current as of commit eaccb43):**
- headless.sh: REH defaults :163-164 inside `assert_vscodium_reh_probe()`; download URL formula :200; env docs :57-60; run dir :546; probe invoked :416.
- editor-smoke.sh: `ALL_STAGES=(debian alpine fedora egress)` :29, `VSCODE_STAGES` :30 (code skips alpine); `editor_bin()` :125-145 (JAILBOX_EDITOR then PATH, codium preferred); `setup_logging()` :101-105; egress stage reuses the debian test image (:71-74); installs its own proof VSIX from `fixtures/proof-extension/`, relies on remote extension preinstalled by CI setup.
- wrapper-images.sh: sources runtime-security.sh at :137 (source versions.env after it); dev-images build `-f dev-images.Containerfile` :241 with `--build-arg DEV_IMAGE` :252; run dir :369; images named `jailbox-test-<stage>`.
- setup-linux.sh: code install :31-37 (`/latest/` URL), codium via vscodium apt repo :39-48. setup-common.sh verifiers :43-51 (print `--version`, grep extension by id only).
- dev-images.Containerfile: `debian:12` in THREE stages (debian, uid-owned-by-other-user, user-conflict), `alpine:3.21`, `fedora:41`.
- README.md tested-configs section :215-225; false gate claim at :217.

**Don't confuse:** repo-root `.env` is empty and unrelated; `jailbox.conf` (`DEV_IMAGE=debian:trixie`) is a sample project config, not a pin file. `container/tinyproxy/Containerfile` is built at runtime by jailbox itself — do NOT parametrize it; enforce alignment via the Step 5 `--check` instead.

**Verify at implementation time (assumed, not yet confirmed):**
- VSCodium .deb asset name pattern on GitHub releases (`codium_<version>_amd64.deb`?).
- Exact `codium --version` line-1 format (bare `1.116.02821` or suffixed) before writing the strict verifier grep.
- open-vsx VSIX URL pattern `https://open-vsx.org/api/jeanp413/open-remote-ssh/<ver>/file/jeanp413.open-remote-ssh-<ver>.vsix`.
- `code --install-extension id@version` works against the marketplace (expected yes).
- Initial `CODE_VERSION` / `REMOTE_SSH_VERSION` / `OPEN_REMOTE_SSH_VERSION` values: resolve current latest at landing time and pin those.

## Verification

- Step 1: `bash tests/run --core-tests` locally (or at minimum `tests/integration/wrapper-images.sh` + headless alpine stage) — identical behavior, REH probe still passes with defaults now sourced from versions.env; `JAILBOX_E2E_REH_RELEASE/COMMIT` overrides still win.
- Step 2: run `tests/ci/setup-linux.sh --with-editors` in a disposable Ubuntu 24.04 container/VM; verify `code --version`/`codium --version` match the pins and both extensions report the pinned versions. `bash scripts/lint.sh` green.
- Step 3: run each of the three test scripts once; confirm `testlog/*/meta.env` exists with populated fields (and `unknown` fallbacks, never a failed run, when e.g. git or podman data is missing).
- Step 4: `bash scripts/resolve-latest-versions.sh` locally (prints latest versions + has_new). Then `gh workflow run canary.yml -f force=true` and watch a full run: with pins already current expect early-exit path; with a stale pin expect the suite + a direct bump commit on master (or a deduped issue on failure).
- Step 5: `scripts/gen-tested-matrix.sh --check` green; hand-edit the README block → `--check` fails; `--write` restores it. Intentionally mismatch tinyproxy FROM → `--check` fails.
