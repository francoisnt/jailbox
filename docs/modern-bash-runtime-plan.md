# Modern Bash host runtime

## Goal

Require Bash 5 or newer for jailbox host orchestration. On macOS, users install
modern Bash through Homebrew or provide another compatible interpreter. jailbox
does not bundle Bash and does not change the user's login shell.

This requirement must land before any feature begins using associative arrays,
namerefs, `mapfile`, or other syntax unavailable in macOS Bash 3.2.

## User experience

On macOS with Homebrew:

```sh
brew install bash
```

No `chsh` or `/etc/shells` change is required. jailbox selects modern Bash only
for its own process.

When no compatible interpreter is available, fail before loading project
configuration or invoking Podman:

```text
Error: jailbox requires Bash 5 or newer.
Install it on macOS with: brew install bash
Or set JAILBOX_BASH to a compatible Bash executable.
```

## Launcher and interpreter selection

Replace the installed `jailbox` entrypoint with a small POSIX `sh` launcher and
move the Bash implementation to a separate installed file. The launcher must
never parse Bash 5 syntax.

Interpreter selection is deterministic:

1. Use `JAILBOX_BASH` when explicitly set, after validating that it is an
   executable Bash 5-or-newer interpreter.
2. Use `bash` from `PATH` when it satisfies the minimum version.
3. On macOS, check Homebrew's Bash through `brew --prefix bash`, then the
   standard Apple Silicon and Intel Homebrew paths.
4. Otherwise fail with installation guidance.

Do not download or install Bash automatically. Do not silently fall back to
macOS `/bin/bash` 3.2.

Avoid a hard-coded Homebrew path as the only mechanism: MacPorts, Nix, managed
workstations, and non-default Homebrew prefixes remain supported through
`JAILBOX_BASH` and `PATH`.

## Installer and release packaging

Keep `install.sh` compatible with macOS Bash 3.2, or convert its bootstrap path
to POSIX `sh`, so it can install jailbox before modern Bash is available and
then report the missing runtime clearly.

Update release packaging and lifecycle checks to include both the portable
launcher and the Bash implementation. Install, update, uninstall, and streamed
release installation must preserve the launcher-to-implementation relationship.

## Compatibility policy

- Host orchestration in `jailbox` and `host/` targets Bash 5 or newer.
- Installer/bootstrap code retains its explicitly documented portable shell
  baseline.
- `container/setup.sh` and `container/entrypoint.sh` remain POSIX `sh`.
- `container/downloader-proxy-manager.sh` remains Bash and uses the container's
  installed Bash; its minimum version must be validated separately before
  adopting Bash 5-only syntax there.
- Linux remains supported through a system or user-installed Bash 5+.

Update `AGENTS.md`, contributor documentation, README prerequisites, script
headers, and ShellCheck configuration together when the minimum changes. Remove
Bash 3.2 compatibility guidance only after the launcher and minimum-version
checks have landed.

## Migration sequence

1. Add the portable launcher, separate Bash implementation, version detection,
   and `JAILBOX_BASH` override while the implementation still runs on Bash 3.2.
2. Update installation, release packaging, and lifecycle tests for the split
   entrypoint.
3. Update Linux and macOS CI to exercise the declared minimum Bash version.
4. Update public and contributor documentation and make Bash 5 the enforced
   minimum.
5. Only then adopt modern Bash features in host modules and remove compatibility
   workarounds.

Each step must leave released installations runnable; do not combine an
interpreter requirement with an untested entrypoint migration.

## Tests

- The launcher rejects Bash 3.2 and Bash 4 with a clear error.
- `JAILBOX_BASH` selects a compatible non-default interpreter.
- An invalid, non-executable, or non-Bash override fails clearly.
- PATH selection works on Linux.
- Homebrew selection works on Apple Silicon and Intel path layouts.
- Arguments, empty strings, signals, stdout, stderr, and exit status pass
  unchanged through the launcher.
- Install, update, uninstall, source-checkout, and streamed-release workflows
  install and invoke the correct files.
- The portable gate runs host tests under the minimum supported Bash and a
  current Bash release.

Run `tests/run portable`. Also run the runtime and editor gates on macOS and
Linux before releasing the new prerequisite because the launcher affects every
command and launch path.

## Non-goals

- No bundled Bash binaries.
- No automatic Homebrew or Bash installation.
- No login-shell changes.
- No zsh implementation or separate macOS code path.
