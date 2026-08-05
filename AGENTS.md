# Repository instructions for coding agents

## Scope and purpose

These instructions apply to the entire repository.

jailbox is a Bash-based host tool that wraps an existing development image
with OpenSSH and runs it as a hardened Podman container. Security behavior and
the claims in the README are part of the product contract. Prefer small,
auditable changes and preserve secure defaults.

## Repository map

- `jailbox`: host CLI entrypoint and command dispatch.
- `host/`: host-side orchestration modules sourced by `jailbox`.
- `container/`: wrapper/proxy image files and container-side scripts.
- `scripts/`: repository, release, and generated-file tooling.
- `tests/`: unit, distribution, runtime, and editor tests.
- `.github/workflows/test-gates.yml`: reusable definition of the three CI gates.
- `host/public-api.sh`: canonical public configuration keys and CLI flags.

Keep host orchestration in `host/`, container behavior in `container/`,
maintenance tooling in `scripts/`, and test code in `tests/`.

## Git and release safety

- Do not create or amend a commit unless the user explicitly asks for a commit.
- Do not infer permission to commit from a request to fix, implement, test, or
  finish a change.
- Do not push, force-push, create tags, open pull requests, or trigger releases
  unless the user explicitly requests that specific action.
- Before an explicitly requested commit, inspect the complete staged diff and
  exclude unrelated or untracked files.
- Never stage, inspect, print, or commit `.env` files unless the user explicitly
  identifies a specific file and asks for that action.
- Preserve unrelated worktree changes. Do not reset, restore, or overwrite user
  changes to make the tree clean.

## Shell compatibility and style

- Use Bash for `jailbox`, `host/`, `scripts/`, and tests. Preserve
  `set -euo pipefail` in executable Bash scripts.
- Host-side code and the portable gate must work with macOS Bash 3.2 as well as
  current Linux Bash. Avoid newer-only features such as namerefs and `mapfile`.
- Under `set -u`, expand arrays that may be empty with a Bash 3.2-safe form such
  as `${array[@]+"${array[@]}"}`. For an array whose valid elements cannot be
  empty, test it with `${array[*]-}` instead of `${#array[@]}`.
- `container/setup.sh` and `container/entrypoint.sh` are POSIX `sh`; do not add
  Bash syntax to them. `container/downloader-proxy-manager.sh` is Bash.
- Quote expansions, use explicit error handling, and avoid evaluating project
  configuration as shell code.
- Keep functions focused and follow the existing formatting and naming style.

## Security invariants

Changes must preserve these properties unless the user explicitly requests a
documented security-model change:

- Read-only container root filesystem.
- No added Linux capabilities and `no-new-privileges` enabled.
- No Docker or Podman socket mounted into the development container.
- Project-scoped runtime state outside the project tree.
- Fresh SSH credentials and strict host-key checking.
- Built-in protected project paths remain additive and read-only.
- Egress mode has no direct external route; outbound HTTP(S) passes through the
  allowlisting proxy sidecar.
- Configuration remains a strict data format and cannot execute shell syntax.

When changing a security-sensitive path, update or add a regression assertion
at the lowest useful layer and ensure the README threat model stays accurate.

## Test gates

There are exactly three user-facing test gates:

```bash
tests/run portable
tests/run runtime
tests/run editor
```

- `portable`: ShellCheck, generated-file checks, every `tests/unit/*.sh` suite,
  syntax checks, release packaging, and the install/update/uninstall lifecycle.
- `runtime`: wrapper-image/container security assertions and the headless CLI
  system test. Requires Linux and Podman.
- `editor`: wrapper-image validation followed by real VS Code or VSCodium Remote
  SSH behavior. Requires Podman, an editor, and a display or Xvfb.

Run `tests/run portable` for every code change. Also run `tests/run runtime`
for host, container, SSH, mount, network, or lifecycle changes when Podman is
available. Run `tests/run editor` for editor integration changes. If a required
gate cannot run in the current environment, state that clearly in the handoff.

Do not add another user-facing test mode without explicit agreement. New unit
scripts are discovered automatically. Keep `scripts/lint.sh` discovery-based so
new test scripts cannot silently escape ShellCheck.

## Workflows and generated content

- Pull requests use the portable and runtime gates.
- Releases and canary runs use portable, runtime, and editor gates.
- Keep shared gate implementation in `.github/workflows/test-gates.yml`; caller
  workflows should pass inputs instead of duplicating test jobs.
- Run `scripts/gen-tested-matrix.sh --check` after changing tested versions or
  matrix inputs; the portable gate also performs this check.
- Changes to `host/public-api.sh` affect release-version selection. Review the
  generated public API diff and documentation when changing config keys or CLI
  flags.

When `.github/workflows` or another protected path is mounted read-only, do not
bypass that protection. Prepare replacement files in a writable location and
tell the user exactly where they must be moved, or ask the user to make the
host-side edit.

## Handoff expectations

Summarize the behavioral result, list the gates actually run, identify anything
that could not be verified, and mention remaining worktree files relevant to the
task. Do not report a gate as passing when only part of it ran.
