# Modern Bash host runtime

## Goal

Require Bash 4.4 or newer for jailbox host orchestration. This allows host code
to use associative arrays, namerefs, `mapfile`, and safe empty-array expansion
under `set -u`.

The runtime requirement must land before host modules adopt syntax unavailable
in macOS Bash 3.2.

## User experience

`jailbox` resolves Bash through `PATH`:

```sh
#!/usr/bin/env bash
```

On macOS, users install a current Bash with:

```sh
brew install bash
```

No login-shell change is required. When jailbox is invoked with an older Bash,
it fails before loading configuration or invoking Podman:

```text
Error: jailbox requires Bash 4.4 or newer (found 3.2.57).
Install it on macOS with: brew install bash
```

## Implementation

### 1. Select and guard the runtime

Change the `jailbox` shebang from `#!/bin/bash` to
`#!/usr/bin/env bash` so a modern Bash installed through Homebrew or another
package manager can be selected through `PATH`.

Immediately after the shebang, before `set -euo pipefail` and before sourcing
host modules, reject Bash versions older than 4.4. Keep this small part of the
entrypoint parseable by Bash 3.2 so macOS system Bash prints the useful error
instead of a syntax error.

Use a Bash 3.2-compatible comparison of `BASH_VERSINFO[0]` and
`BASH_VERSINFO[1]` to reject versions below 4.4.

Do not adopt Bash 4.4-only syntax in `jailbox` itself. Host modules may use it
because they are sourced only after the guard passes.

`install.sh` remains unchanged. It continues to use `/bin/bash` and remain
compatible with macOS Bash 3.2. Running `jailbox`, including
`jailbox --uninstall`, requires Bash 4.4 or newer. A user without modern Bash
can uninstall directly with the installed `install.sh --uninstall`; document
that fallback in the README.

### 2. Update macOS CI

In the Darwin branch of `tests/ci/setup-portable.sh`:

- Install Homebrew Bash.
- Add `$(brew --prefix bash)/bin` to `PATH` through the existing `prepend_path`
  helper so it persists into later GitHub Actions steps.
- Verify that `command -v bash` resolves to Bash 4.4 or newer.

In `tests/portable/smoke.sh`, add a macOS assertion that `/bin/bash jailbox`
reports the version error. This checks the real system Bash 3.2 path and
preserves the friendly failure mode.

### 3. Test the minimum and current runtimes

Run the complete portable gate in two Linux environments:

- Bash 4.4, the minimum supported version.
- The runner's current Bash.

The Bash 4.4 job builds and may cache the pinned upstream 4.4.18 release. Its
`bin` directory must be written to `$GITHUB_PATH`, and the gate must print
`command -v bash` and `bash --version` immediately before running so a path
error cannot silently test the runner Bash instead.

If Bash 4.4.18 cannot be maintained on the CI runner without source patches or
fragile workarounds, select the oldest practical later version and update the
guard and documentation before landing.

Do not create a matrix for every intermediate Bash release. The minimum catches
use of syntax newer than the contract, while the current runner catches modern
behavior and upstream drift.

Verify that `tests/run portable` passes with Bash 4.4 and the current runner
Bash. The macOS smoke assertion provides the unsupported-runtime test.

Runtime and editor gate coverage remains unchanged. Those gates exercise
Podman and editor integration, not the supported Bash range.

### 4. Document the requirement

Update the relevant documentation:

- Add the Bash 4.4 floor and macOS Homebrew command to README prerequisites,
  and resolve its current Linux-only platform statement before claiming macOS
  runtime support.
- `CONTRIBUTING.md` with the development and test requirement.
- `AGENTS.md` so `host/` may use Bash 4.4 features while `jailbox` remains Bash
  3.2-parseable and `install.sh` remains Bash 3.2-compatible. Tooling and tests
  keep their current compatibility unless a later change needs otherwise.
- `plans/supported-versions.md` so it describes minimum-and-current Bash
  coverage rather than a matrix of every Bash series.

Keep `${array[@]+"${array[@]}"}` where Bash 3.2 compatibility still applies.
Keep the version-independent `${array[*]-}` guidance for testing whether an
array whose elements cannot be empty has any entries.

Do not store the minimum Bash version in `versions.env`; that file contains
moving external version pins, while the Bash floor is a stable runtime
requirement.

## Change order

Land the runtime contract as one change:

1. Add the `env bash` shebang and early version guard to `jailbox`.
2. Give macOS CI a modern Bash and add the minimum/current portable coverage.
3. Add the real-interpreter and failure-message tests.
4. Update the user, contributor, agent, and supported-version documents.

Adopt modern Bash constructs in host modules in a later change. This keeps the
runtime-policy change small and makes any resulting behavior change easier to
review.

## Non-goals

- Bundling or automatically installing Bash on user machines.
- Changing the user's login shell.
- Testing every Bash minor series.
- Supporting Bash older than 4.4 for host orchestration.
- Adding a launcher, re-exec mechanism, or `JAILBOX_BASH` override.
- Changing the runtime or editor test platforms.
- Testing Bash 4.0 through 4.3 or non-Bash interpreters.
- Adding associative-array security guidance before associative arrays are
  introduced.

## Verification

Run:

```sh
tests/run portable
```

The CI Bash 4.4 job runs the same gate. Runtime and editor gates are not required
for this documentation, entrypoint, and CI-only change because container,
network, SSH, and editor behavior are unchanged.
