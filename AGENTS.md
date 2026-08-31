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
- Move tracked files with `git mv` so Git records their history cleanly. Always
  use `git mv` when moving completed plans into `plans/archive/`.
- Preserve unrelated worktree changes. Do not reset, restore, or overwrite user
  changes to make the tree clean.

## Shell compatibility and style

- Use Bash for `jailbox`, `host/`, `scripts/`, and tests. Preserve
  `set -euo pipefail` in executable Bash scripts.
- Host modules and the portable gate require Bash 4.4 or newer. The `jailbox`
  entrypoint before its version guard must remain parseable by macOS Bash 3.2,
  and `install.sh` must remain compatible with Bash 3.2.
- In Bash 4.4-or-newer code, expand possibly empty arrays normally with
  `"${array[@]}"`. Keep the Bash 3.2-safe `${array[@]+"${array[@]}"}` form in
  `install.sh` and any code explicitly required to support Bash 3.2. For an
  array whose valid elements cannot be empty, test it with `${array[*]-}`
  instead of `${#array[@]}`.
- `container/setup.sh` and `container/entrypoint.sh` are POSIX `sh`; do not add
  Bash syntax to them. `container/downloader-proxy-manager.sh` is Bash.
- Quote expansions, use explicit error handling, and avoid evaluating project
  configuration as shell code.
- Validate configuration-derived and other untrusted associative-array
  subscripts before lookup. Never use an untrusted subscript in an arithmetic
  context where Bash may expand it more than once.
- Keep functions focused and follow the existing formatting and naming style.
- Declare mutable host state in the module that owns its lifecycle. Keep shared
  project/resource identity in `host/common.sh`, image state in
  `host/dev-image.sh`, SSH state in `host/ssh.sh`, editor state in
  `host/editor.sh`, network state in `host/network.sh`, and mount/runtime state
  in `host/container-runtime.sh`.

## Security invariants

Changes must preserve these properties unless the user explicitly requests a
documented security-model change:

- Read-only container root filesystem.
- No added Linux capabilities and `no-new-privileges` enabled.
- No Docker or Podman socket mounted into the development container.
- Project-scoped runtime state outside the project tree.
- Fresh SSH credentials and strict host-key checking.
- Protected project paths are validated before launch and mounted read-only,
  and project configuration cannot remove a path jailbox protects
  automatically.
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
- `editor`: preparation of the positive wrapper images required by the selected
  editor, followed by real VS Code or VSCodium Remote SSH behavior. The runtime
  gate exclusively owns the editor-independent wrapper/container security
  contract and its negative image cases. Requires Podman, an editor, and a
  display or Xvfb.

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

## Plan authoring

- Write plans as final, settled implementation documents. If the user's intent
  is unclear, ask before writing the plan; do not put unresolved approval
  questions, speculative alternatives, or requests for decisions into it.
- Center plans on observable behavior, security invariants, public interfaces,
  migration, ordering constraints, acceptance criteria, and non-goals. Leave
  helper names, internal state choreography, exact shell techniques, and test
  fixture construction to the implementer unless one of those details is
  necessary to preserve correctness, portability, or a security boundary.
- Treat any implementation notes retained in a plan as non-binding guidance.
  An implementer may choose a simpler internal design when it satisfies the
  complete contract and acceptance criteria and respects this file's module
  ownership rules.
- When revising a plan removes or replaces earlier behavior, rewrite the
  affected passages as though the superseded material had never been present.
  Do not retain history about the discarded direction or statements that the
  plan will not implement it.
- Distinguish discarded plan text from existing implementation artifacts. When
  the current code, public API, tests, or documentation still contains behavior
  replaced by the plan, include explicit migration or removal steps and name
  the affected symbols and files. A final plan must describe all work required
  to move the repository from its current state to the planned state.
- Whenever the user gives a new standing instruction about how agents should
  work in this repository, update this `AGENTS.md` in the same change so later
  sessions inherit it.
- Do not cite a plan document from `AGENTS.md`. Plans are ephemeral and are
  archived once implemented; every instruction here must stand on its own.

## Handoff expectations

Summarize the behavioral result, list the gates actually run, identify anything
that could not be verified, and mention remaining worktree files relevant to the
task. Do not report a gate as passing when only part of it ran.
