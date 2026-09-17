# Repository instructions for coding agents

## Scope and purpose

These instructions apply to the entire repository.

jailbox is a Bash-based host tool that wraps an existing development image
with OpenSSH and runs it as a hardened Podman container. Security behavior and
the claims in the README are part of the product contract. Prefer small,
auditable changes and preserve secure defaults.

A first-party orchestrator consuming jailbox's machine interface is planned,
not hypothetical. The machine-interface features in the 03.2 plan series
(`config-schema`, `status`, `connection-info` with forward-compatible trailing
fields, the version/bump policy and range pinning) exist for it; do not flag
them as speculative productization or complexity without a consumer.

## Repository map

- `jailbox`: host CLI entrypoint and command dispatch.
- `host/`: host-side orchestration modules sourced by `jailbox`.
- `container/`: wrapper/proxy image files and container-side scripts.
- `scripts/`: repository, release, and generated-file tooling.
- `tests/`: unit, distribution, runtime, and editor tests.
- `.github/workflows/test-gates.yml`: reusable definition of the four CI gates.
- `host/public-api.sh`: canonical public configuration keys and CLI flags.

Commands, flags, and configuration-key membership must come from
`host/public-api.sh`. Derive consuming lists from those declarations. Where a
consumer needs per-member behavior or metadata, validate that its mapping covers
every applicable declaration exactly; missing mappings must fail explicitly.
Keep regression tests proving that new declarations propagate or fail for a
missing mapping, rather than silently falling through or losing coverage.
Declare commands that manage sandbox containers, networks, and home state in
`CLI_LIFECYCLE_COMMANDS`; declare other commands in `CLI_OTHER_COMMANDS`.
Derive lifecycle test membership directly from that public category.
Lifecycle commands also require validated test contracts and fault scenarios
in `tests/lib/lifecycle-contracts.sh` before the matrix schedules them.

Keep host orchestration in `host/`, container behavior in `container/`,
maintenance tooling in `scripts/`, and test code in `tests/`.

## Git and release safety

- Do not stage changes unless the user explicitly asks for staging. In
  particular, when reviewing staged changes and then applying requested fixes,
  leave those fixes unstaged so the user can inspect the new diff separately.
- Do not create or amend a commit unless the user explicitly asks for a commit.
- When the user asks for a commit, make it on `master` directly. Do not create
  a branch first or offer branching as the default; the user works on `master`.
- Do not infer permission to commit from a request to fix, implement, test, or
  finish a change.
- Treat a request to commit as an instruction to commit the current state, not
  as authorization to make further edits. If review before the commit reveals
  a change that still appears necessary, describe it before acting and wait for
  the user's direction; do not silently include additional edits in the
  requested commit.
- Do not push, force-push, create tags, open pull requests, or trigger releases
  unless the user explicitly requests that specific action.
- Do not add a co-author trailer, a generated-with footer, or any other AI
  watermark to commit messages, even when a tool or harness default says to.
- Before an explicitly requested commit, inspect the complete staged diff and
  exclude unrelated or untracked files.
- Write the commit message to describe only what the commit's own diff does to
  tracked files. Work that leaves no trace in that diff — an uncommitted draft
  removed before staging, an untracked file deleted, a worktree change restored
  to its committed state — must not be announced as something the commit did.
  Where such a decision is worth recording, state it as context without
  implying the commit performed it.
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
- Keep substantive embedded programs in ordinary source files: container
  programs in `container/`, test programs and fake executables in test fixture
  directories, and Python helpers in `.py` files. Pass inputs as arguments,
  environment variables, or stdin instead of interpolating data into code.
  Put substantial trap bodies in functions in the owning module. Tiny commands
  and expressions may remain inline; do not create a file for every one-liner.
  Include extracted programs in the applicable lint, syntax, packaging, and
  runtime checks, preserving stdin, exit status, cleanup, and cache behavior.
- Declare mutable host state in the module that owns its lifecycle. Keep shared
  project/resource identity in `host/common.sh`, image state in
  `host/dev-image.sh`, SSH state in `host/ssh.sh`, editor state in
  `host/editor.sh`, network state in `host/network.sh`, and mount/runtime state
  in `host/container-runtime.sh`.
- Check critical prerequisites and mutations explicitly; `set -e` alone is not
  a failure contract. Before calling a function through `if`, `!`, `&&`, or
  `||`, check its callees too: that context can suppress errexit throughout the
  call chain, including subshell functions. Stop dependent work on failure and
  preserve nonzero status through cleanup.
- Check required data producers before trusting their output. A successful
  consumer of a command/process substitution does not establish producer
  success. Bash normally clears errexit in command substitutions;
  `inherit_errexit` preserves it but does not fix discarded producer statuses
  or conditional-call suppression. Empty output must not turn failure into
  absence or permission to mutate. Separate local declarations from fallible
  assignments when checking the assignment's status. Keep intentional advisory
  fallbacks distinct from required checks.
- Distinguish three kinds of state: temporary values stay local to a function;
  configuration and project identity are treated as read-only by convention
  once finalized; operation state, including attempted creations and rollback
  inventory, has one clear owner with explicit updates. Shared reads are fine;
  avoid hidden writes.
- Prefer pure decision helpers with explicit inputs where they simplify code.
  Keep external effects apparent and separate from decisions. Check required
  initialization at meaningful boundaries and retain useful module-owned state.
- Use subshells for bounded cleanup, directory, or shell-setting scopes that
  need no caller-state updates. Preserve caller traps and settings, explicitly
  handle failures, and clean up external effects; subshells only isolate shell
  state. Keep the design proportional to the demonstrated problem.
- Give temporary artifacts an operation-scoped cleanup owner. Failed preparation
  must not publish partial output; cleanup must preserve pre-existing resources
  and dependencies needed by survivors, and report failures without masking the
  original failure. Do not broaden lifecycle or concurrency guarantees through
  a shell-structure refactor.
- Apply these conventions to demonstrated problems and code being changed,
  rather than mechanically rewriting working functions. Add focused regressions
  for failure sequencing, publication, cleanup, or caller-state isolation where
  behavior warrants them; test conditional invocation when relevant, not merely
  the arrangement of helpers.

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

There are four primary test gates:

```bash
tests/run portable
tests/run runtime
tests/run matrix
tests/run editor
```

`matrix` owns the full lifecycle state and interruption matrix. It prepares
its required images independently; `runtime` owns container security and the
headless CLI system test.

`tests/run` with no argument runs those same four gates in order and stops at
the first failing suite. It validates every selected gate's prerequisites
before the first suite, so an environment missing Podman, an editor, or a
display fails immediately instead of after the portable gate.

- `portable`: ShellCheck, generated-file checks, every `tests/unit/*.sh` suite,
  syntax checks, release packaging, and the install/update/uninstall lifecycle.
- `runtime`: wrapper-image/container security assertions and the headless CLI
  system test. Requires Linux and Podman.
- `matrix`: required Debian image preparation and the full lifecycle state and
  interruption matrix. Requires Linux, Podman and setsid.
- `editor`: preparation of the positive wrapper images required by the selected
  editor, followed by real VS Code or VSCodium Remote SSH behavior. The runtime
  gate exclusively owns the editor-independent wrapper/container security
  contract and its negative image cases. Requires Podman, an editor, and a
  display or Xvfb.

Run `tests/run portable` for every code change. Also run `tests/run runtime`
for host, container, SSH, mount, network, or lifecycle changes when Podman is
available. Run `tests/run matrix` for lifecycle or matrix changes when its
prerequisites are available. Run `tests/run editor` for editor integration changes. If a required
gate cannot run in the current environment, state that clearly in the handoff.

Permission-sensitive test fixtures must explicitly set the permissions required
by their scenario rather than inherit the caller's umask. Verify relevant
changes under both `0022` and `0002`.
Tests that consume a Git identity must create an isolated dummy identity rather
than rely on or modify the developer's or CI runner's Git configuration.

Do not add another user-facing test mode without explicit agreement. New unit
scripts are discovered automatically. Keep `scripts/lint.sh` discovery-based so
new test scripts cannot silently escape ShellCheck.

## Workflows and generated content

- Pull requests use portable, runtime, and matrix gates.
- Releases and canary runs use all four gates: portable, runtime, matrix, editor.
  Runtime and matrix are independent jobs with no duplicated assertions.
- Keep shared gate implementation in `.github/workflows/test-gates.yml`; caller
  workflows should pass inputs instead of duplicating test jobs.
- Run `scripts/gen-tested-matrix.sh --check` after changing tested versions or
  matrix inputs; the portable gate also performs this check.
- Changes to `host/public-api.sh` affect release-version selection. Review the
  generated public API diff and documentation when changing config keys or CLI
  flags.

When `.github/workflows`, the `jailbox` entrypoint, or another protected path
is mounted read-only, do not bypass that protection. Write the replacement
beside the original in the repository as `<original-name>.new`, matching the
original's mode, and tell the user to rename it over the original; the user
performs that rename, never an agent. If the destination directory is also
read-only, put `<original-name>.new` at the repository root and state its intended
destination; the user will move it into place. Use this fallback instead of
creating a patch solely because adjacent replacements cannot be written.
Do not leave the replacement in a
temporary directory outside the tree, and never stage or commit a `.new` file.
Verify the replacement before handing it over — at minimum a syntax check, and
the affected gates against a copied tree that already carries the change — and
state in the handoff that the rename is still outstanding and what breaks until
it happens.

## Plan authoring

- When editing plans, minimize the diff without sacrificing correctness,
  clarity, or completeness. Preserve existing wording and structure wherever
  they still serve the final design; prefer targeted changes over broad
  rewrites. When restructuring is needed, move existing text with minimal
  rewording and limit other edits to what the requested change requires.
- The current machine-boundary series is one release unit: no release occurs
  until all its plans are implemented and all four test gates pass. Work may
  depend on later plans when dependencies and remaining integration are
  explicitly tracked and accounted for, and all test gates continue to pass.
  Do not require temporary compatibility behavior solely for unreleased
  intermediate states; assess the completed series and its tracked dependencies.
- Record every load-bearing dependency on a future plan at both ends. The
  originating plan identifies the dependency; the receiving plan explicitly
  assigns its implementer the required integration and verification, including
  acceptance criteria. A forward reference alone does not transfer ownership.
- Write plans as final, settled implementation documents. If the user's intent
  is unclear, ask before writing the plan; do not put unresolved approval
  questions, speculative alternatives, or requests for decisions into it.
- Organize every plan in two parts, a broad intent part and an implementation
  detail part, and place every other section under whichever of the two it
  belongs to, so an implementer can tell at a glance what binds them. The
  intent part states precisely what must become true and why, and carries
  observable behavior, external contracts, security invariants, ordering
  constraints, acceptance criteria, and non-goals; that is the plan's job and
  the implementer must respect it. The detail part carries how to build the
  thing, which is the implementer's, and is guidance under the rule below, so
  the implementer keeps room to choose mechanisms. Precision belongs in what
  the plan requires, not in how the requirement is met. This shapes plans you
  write or substantially revise; do not restructure an existing flat plan for
  its own sake.
- Specify an internal detail only where it is load-bearing: an exact byte
  format or record schema another implementation must reproduce, a value
  grammar or validation rule carrying a security boundary, or an ordering
  constraint that prevents a broken intermediate state. Everything else —
  helper and variable names, module structure, state choreography, shell
  technique, test fixture construction — belongs to the implementer. When in
  doubt, state the property the implementer must achieve and let them choose
  the mechanism.
- Name existing symbols and files only where the plan removes or migrates
  them, since that is knowledge about the current repository an implementer
  cannot derive from intent; verify each such name against the tree as you
  write it. Naming symbols the plan creates is not required and tends to go
  stale; where a plan carries such detail anyway, it is guidance under the
  rule below.
- Treat implementation detail in a plan as guidance, never as a specification
  to transcribe. Where a plan names functions, modules, techniques, or an
  ordered procedure, that records one design someone thought through, not the
  only acceptable one. The implementer carries an affirmative duty to build
  the best design they can see: adopt the plan's suggestion where it really is
  the best available option, and improve on it where it is not, provided the
  result satisfies the complete contract, the acceptance criteria, and this
  file's module ownership rules. Improving on the plan needs no amendment;
  changing an external surface does.
- Check a plan's detail against the tree before following it. Plans are
  written ahead of the code and their internal prescriptions go stale as the
  repository moves. Where detail has gone stale, or is simply worse than what
  you can see from inside the work, follow the intent and report the
  divergence in your handoff rather than reproducing the plan literally.
- Before implementing a plan that belongs to a numbered series, read that
  series' umbrella plan first — the one whose number the members extend. It
  carries the ordering, layer ownership, and external-surface decisions that
  bind every member, and the members do not repeat them.
- When revising a plan removes or replaces earlier behavior, rewrite the
  affected passages as though the superseded material had never been present.
  Do not retain history about the discarded direction or statements that the
  plan will not implement it.
- Distinguish discarded plan text from existing implementation artifacts. When
  the current code, public API, tests, or documentation still contains behavior
  replaced by the plan, include explicit migration or removal steps and name
  the affected symbols and files. A final plan must describe all work required
  to move the repository from its current state to the planned state. That
  completeness is about outcomes and removals, not about enumerating the
  construction steps the implementer will choose.
- When you finish implementing a plan, move it into `plans/archive/` (with
  `git mv`) as part of the same work, without waiting to be asked. Archiving
  does not authorize a commit.
- Whenever the user gives a new standing instruction about how agents should
  work in this repository, update this `AGENTS.md` in the same change so later
  sessions inherit it.
- Do not cite a plan document from `AGENTS.md`. Plans are ephemeral and are
  archived once implemented; every instruction here must stand on its own.
- When one plan references another, use the bare filename (or plan number)
  without a `plans/` or `archive/` prefix: the number identifies the plan,
  and prefix-free references do not need rewriting when a plan is archived.
- Plan filenames must sort in implementation order. When a plan's place in the
  order changes, rename it so its number reflects the new order — dotted
  insertion numbers (the 03.1.1 style) are the precedent — and update its
  title heading and every cross-reference. Never leave the old number and
  describe the ordering exception in prose instead.
- Do not reintroduce terminology from retired directions into active
  documents (for example "JailIDE" from the deferred repository split). Refer
  to archived plans neutrally, by number and `plans/archive/` location; the
  old names may remain inside the archive and the rationale documents that
  describe that era.

## User interaction

- Optimize the cost of reaching a result as well as the result itself. Start
  performance investigations with existing evidence and short, representative
  samples. Do not ask the user to run exhaustive suites for initial measurements
  when a sample can answer the question. Use repeats to assess confidence, state
  the limits of sample evidence, and respect the user's requested validation scope.
- For resource-efficiency experiments, identify the variable being tested before
  asking for a run. Tune CPU/RAM per worker with concurrency held fixed; worker
  count alone does not measure worker resource needs. Account for the complete
  worker workload, and distinguish measured usage from enforced limits and
  scheduling allowances.
- When proposing options or changes for approval, print a plain numbered list
  in the reply and let the user answer by number. Do not use interactive
  question menus or selection widgets. Keep each proposal self-contained
  enough to approve or reject independently, and wait for the user's picks
  before editing anything.
- Standing instructions from the user belong in this file, not in any
  tool-private memory or settings, so that every AI tool used on this
  repository inherits them. Read this file at the start of each session.

## Handoff expectations

Summarize the behavioral result, list the gates actually run, identify anything
that could not be verified, and mention remaining worktree files relevant to the
task. Do not report a gate as passing when only part of it ran.
