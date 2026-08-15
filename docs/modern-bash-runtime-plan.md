# Modern Bash host runtime

## Goal

Require Bash 4.4 or newer for jailbox host orchestration, as a documented
prerequisite enforced by a version check. On macOS, users install modern Bash
through Homebrew. jailbox does not bundle Bash and does not change the user's
login shell.

This requirement must land before any feature begins using associative arrays,
namerefs, `mapfile`, or other syntax unavailable in macOS Bash 3.2.

### Minimum version choice

The floor is derived from the features jailbox needs to stay clean, and from
nothing else. It is not set by what CI finds convenient to provision, and not by
what is newest. Excluding a user is a cost paid for a named benefit:

| Feature | Introduced | Why jailbox wants it |
| --- | --- | --- |
| Associative arrays, `mapfile` | 4.0 | Replaces parallel indexed arrays and `while read` loops |
| Namerefs (`local -n`) | 4.3 | Lets helpers write to a caller's array without globals |
| `"${a[@]}"` on an empty array under `set -u` | **4.4** | Removes the `${array[@]+"${array[@]}"}` idiom repo-wide |

The binding constraint is 4.4, and it is the least glamorous of the three. Bash
4.4 stopped throwing an unbound-variable error when `${a[@]}` or `${a[*]}`
expands an array with no assigned elements under `nounset` (bash `CHANGES`, 4.4
series). That is what retires the guard form `AGENTS.md` currently mandates for
every possibly-empty array — `READONLY_MOUNTS`, `EGRESS_ALLOW`, `ROOTFS_FLAG`,
`SSH_SESSION_ENV`, and the rest. Measured by maintainability, that single change
is worth more than namerefs.

So the floor is **4.4**. Nothing jailbox needs lives above it.

### What 4.4 excludes

macOS system Bash (3.2) and Amazon Linux 2 (4.2). RHEL/CentOS 8 (4.4),
Ubuntu 18.04 (4.4), and Debian 10 (5.0) are all inside the floor. Excluded hosts
remain usable by installing a newer Bash ahead of the system one on `PATH`.

### The 5.2 subscript change is a constraint, not a floor

Bash's `COMPAT` document records that 5.2 changed the expansion of array
subscripts in arithmetic contexts, acting as if `assoc_expand_once` were set
(entry 66), and changed how `unset` treats `@` and `*` subscripts (entry 67).
Below 5.2, `arr[$key]` in an arithmetic context is expanded twice.

This is a real hazard — a key drawn from `jailbox.conf` and double-expanded is a
code-execution path, which matters more than usual for a sandboxing tool — but
it is not a reason to require 5.2. It is a reason to write subscripts that are
safe under both semantics, and to let the version matrix catch violations.
`shopt -s assoc_expand_once` is not available as an escape hatch, since it
arrived in 5.0 and the floor is 4.4.

Treat it as a coding rule: never place an unquoted, non-literal subscript in an
arithmetic context. The 4.4 job in the matrix is what enforces it.

### Moving the floor later

The floor moves when a named feature justifies it, and at no other time. Not on
a schedule, not because a runner image drifted, not because a version is old.
Raising it is a user-facing exclusion and needs the same justification as the
table above.

In particular, the floor does not follow CI. The version matrix exists to prove
the floor, so the floor is never adjusted to whatever happens to be convenient
to provision — that would be the same drift that keeps the value out of
`versions.env`, arriving by a different route.

## User experience

On macOS with Homebrew:

```sh
brew install bash
```

No `chsh` or `/etc/shells` change is required, and no jailbox-specific
environment variable is involved. Homebrew puts its `bin` directory ahead of
`/usr/bin` on `PATH`, which is all jailbox needs.

When no compatible interpreter is available, fail before loading project
configuration or invoking Podman:

```text
Error: jailbox requires Bash 4.4 or newer (found 3.2.57).
Install it on macOS with: brew install bash
```

## Implementation

Three changes. There is no launcher, no second installed file, and no change to
packaging or the install layout.

### 1. Resolve Bash through `PATH`

Change the `jailbox` shebang from `#!/bin/bash` to `#!/usr/bin/env bash`.

On macOS, `#!/bin/bash` is hard-wired to the system 3.2 even when a modern Bash
is installed. `env bash` picks up Homebrew's Bash for anyone who ran
`brew install bash`, and equally serves MacPorts, Nix, and managed workstations,
because they all work by putting their `bin` directory on `PATH`. On Linux it is
a no-op for system Bash and lets a user-installed newer Bash win.

`scripts/lint.sh` already uses this form; the rest of the repository does not.

#### Callers that bypass the shebang

A shebang only applies when a file is executed directly. The repository
frequently invokes scripts as `bash tests/run portable`, `bash
scripts/build-tarball.sh`, and `bash "$tmp_dir/$release_dir/install.sh"`, all of
which ignore the target's shebang.

These are safe as written, because they resolve `bash` through `PATH` — the same
interpreter `#!/usr/bin/env bash` would select. The rule to hold is therefore
narrower than "callers must use PATH": no hardcoded absolute interpreter path
may appear in a caller, since `/bin/bash foo.sh` on macOS pins 3.2 regardless of
what `foo.sh` declares.

The repository currently contains no such absolute invocation. This plan
introduces exactly one, deliberately — `/bin/bash -n jailbox` in the portable
gate — and it must remain the only one. README and contributor documentation
must not print an absolute interpreter path in a copyable command either.

### 2. Guard the version in the entrypoint

Immediately after the shebang, before `set -euo pipefail` and before any module
is sourced:

```sh
jailbox_bash_too_old() {
    printf 'Error: jailbox requires Bash 4.4 or newer (found %s).\n' \
        "${BASH_VERSION:-unknown}" >&2
    printf 'Install it on macOS with: brew install bash\n' >&2
    exit 1
}

if [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    jailbox_bash_too_old
fi
if [ "${BASH_VERSINFO}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; then
    jailbox_bash_too_old
fi
```

It runs before `set -euo pipefail`, before `apply_config_defaults`, and before
any Podman call, which satisfies the fail-early requirement.

The two separate `if` statements are load-bearing and must not be merged. A
minor-version floor needs `BASH_VERSINFO[1]`, but `${VAR[1]}` is a "Bad
substitution" error in `dash` and other POSIX shells, so `sh jailbox` would fail
with shell noise instead of the real reason. Splitting the test means the first
`if` — which uses only `${BASH_VERSINFO:-0}`, valid everywhere as a plain
variable — catches both non-Bash shells and Bash below 4, and exits before the
subscript form is ever parsed. Verified: `dash`, `sh`, and Bash 3.2 all reach
the message; merging the conditions into one statement breaks `dash` and `sh`.

The `-eq 4` on the second test is also required, so that Bash 5.0 and 5.1 are
not rejected for having a minor version below 4.

The guard is a hard failure. There is no warning variant and no grace period —
there are no installs to protect, and a two-state guard would mean two versions
of this snippet to write, test, and keep consistent.

The guard is still worth having with no users. Its purpose is not migration; it
is to give the *first* user without Bash 4.4 a clear instruction instead of a
parse error or a confusing failure deep inside a Podman call.

### 3. Document the prerequisite

Update README prerequisites, `AGENTS.md` shell compatibility rules, and
`CONTRIBUTING.md`.

The Bash floor does **not** go in `versions.env`. That file is a set of external
version *pins* — versions jailbox is tested against and bumps forward — and its
automation is built on that meaning:

- The canary workflow rewrites it on green. A canary passing on Bash 5.3 must
  not silently raise the floor to 5.3.
- `scripts/resolve-latest-versions.sh` compares each pin against latest upstream
  and reports drift. A floor is supposed to lag latest; it would be permanent
  false-positive noise.
- `scripts/gen-tested-matrix.sh` renders the pins as the README "Tested
  Configurations" table. A minimum requirement is not a tested configuration.

A pin answers "what do we test with"; a floor answers "what do we refuse below".
Storing the second in a file whose automation assumes the first would let a
green canary edit the project's stated requirements.

The guard in `jailbox` is the source of truth, because it is the only place the
value is enforced rather than described. README, `AGENTS.md`, and
`CONTRIBUTING.md` restate it in prose and are kept honest by the guard tests.

## The one invariant, and how it is enforced

The `jailbox` entrypoint must stay parseable by Bash 3.2, so that a user without
modern Bash reaches the guard instead of a raw parse error. `host/*.sh` are
under no such constraint: they carry no shebang, are only ever sourced, and are
parsed by the already-running interpreter after the guard has passed.

This is enforced, not left to convention. `tests/portable/smoke.sh` already runs
`bash -n` across every shell file; split that check so the entrypoint is held to
the older parser:

- `/bin/bash -n jailbox install.sh` on macOS, where `/bin/bash` is 3.2.
- `bash -n` for `host/*.sh` and everything else, under the current Bash.

A contributor who puts Bash 4.4 syntax in `jailbox` itself fails the portable
gate on macOS. The consequence of the invariant breaking is also mild — a user
who already lacks Bash 4.4 sees an ugly error instead of a clear one — so the
enforcement is proportionate.

## Compatibility policy

- `host/` targets Bash 4.4 or newer.
- `jailbox` targets Bash 4.4 at runtime but must remain Bash 3.2-parseable.
- `install.sh` stays Bash 3.2-compatible. It runs before modern Bash is
  necessarily present, so it must be able to install jailbox and let the guard
  report the missing runtime.
- `container/setup.sh` and `container/entrypoint.sh` remain POSIX `sh`.
- `container/downloader-proxy-manager.sh` remains Bash and uses the container's
  installed Bash; its minimum version must be validated separately before
  adopting Bash 4.4-only syntax there.
- `scripts/` and `tests/` may adopt Bash 4.4 syntax, but each file that does needs
  its shebang changed to `#!/usr/bin/env bash` for the same reason as the
  entrypoint.

ShellCheck cannot enforce any of this. It has no target-version flag and will
not flag Bash 4 or 5 syntax against an older baseline, so it never was the
mechanism holding the current floor. The `bash -n` split above and the
interpreter CI runs under are the enforcement.

Update these together, so no document is left asserting the old floor:
`AGENTS.md`, README prerequisites, `CONTRIBUTING.md`, and the in-flight plans
that carry their own Bash 3.2 constraints — `docs/stub-directories-plan.md`,
`docs/headless-mode-plan.md`, and `docs/writable-paths-plan.md`.

## Change set

jailbox has no users yet, so there is no migration: no staged releases, no grace
period, no compatibility window. Land the floor as one change.

1. `#!/usr/bin/env bash` in `jailbox`, plus the version guard.
2. Split the `bash -n` check in `tests/portable/smoke.sh`.
3. Update `AGENTS.md`, README prerequisites, and `CONTRIBUTING.md`.

Adopting Bash 4.4 features in `host/` should still be a separate commit, but for
dependency reasons rather than release safety: until the shebang change lands,
`declare -A` in a host module breaks jailbox on any macOS machine, including the
one it is being written on. Once the floor is in, the constraint is gone and
feature adoption proceeds normally.

The only sequencing risk left is a self-inflicted one. Changing the shebang
moves macOS development from Bash 3.2 to 5.x, which is where a latent 3.2-era
assumption in `host/` would surface. Run the runtime and editor gates on macOS
once after the change, before building on top of it.

## Tests

- The guard rejects Bash 3.2 with a clear error, invoked as
  `/bin/bash jailbox` on macOS.
- The guard rejects a non-Bash interpreter with the same error, tested with both
  `sh jailbox` and `dash jailbox`. This is the regression test for the split
  `if` statements; a merged condition fails here with "Bad substitution".
- `jailbox` parses under Bash 3.2 (`/bin/bash -n jailbox`).
- A modern Bash earlier on `PATH` than the system one is selected, and jailbox
  reaches normal argument handling.
- Invocation through the installed `$BIN_DIR` symlink still resolves `host/`.
  This is existing behaviour in `resolve_script_path` and is unchanged by the
  shebang, but it is the path every user takes and is currently untested.
- The portable gate runs under every supported Bash version (see the matrix
  below) and prints `bash --version` in its output, so the tested interpreter is
  a recorded fact rather than an inference from the runner image.
- The `${array[@]+"${array[@]}"}` removals behave identically on 4.4 and on the
  newest Bash. This is the change the floor was chosen to enable, so it is the
  one that most needs both ends of the range.

### Bash version matrix

A declared floor of 4.4 is a claim about five releases — 4.4, 5.0, 5.1, 5.2, and
5.3 — and every one of them should be exercised. Supporting a version without
testing it is an assumption, and the whole point of deriving the floor from
features is that the resulting claim is honest.

The matrix applies to the **portable gate only**. That gate is ShellCheck, unit
tests, the release tarball, and the install lifecycle; it needs no Podman, no
GUI, and no privileges, so it is cheap to multiply. The runtime and editor gates
need a container runtime and a real editor and stay on the existing OS matrix —
they test jailbox's interaction with the outside world, not Bash semantics.

Build the interpreters from source on one current Linux runner. Do not use old
distro images.

| Bash | Source |
| --- | --- |
| 4.4.18 | `ftp.gnu.org/gnu/bash`, built |
| 5.0.18 | `ftp.gnu.org/gnu/bash`, built |
| 5.1.16 | `ftp.gnu.org/gnu/bash`, built |
| 5.2.37 | `ftp.gnu.org/gnu/bash`, built |
| newest | runner default and Homebrew, via the existing gates |

Old base images look like the cheap option and are not:

- **They vary the wrong thing.** `ubuntu:18.04` brings not just Bash 4.4 but
  coreutils 8.28, an old `sed`, and ShellCheck 0.4.x. A red job would not say
  whether Bash 4.4 broke or ancient `realpath` did. `tests/ci/setup-portable.sh`
  already installs coreutils and prepends `gnubin` precisely because the suite
  depends on modern userland. One host with N interpreters changes exactly one
  variable, which is the entire point of the matrix.
- **Distro Bash is patched Bash.** Debian's 5.2 is not vanilla 5.2. The floor is
  a claim about upstream 4.4, not about whatever Ubuntu 18.04 shipped and then
  backported into.
- **The images are EOL.** `ubuntu:18.04` and `debian:10` are already past end of
  life; depending on them means the matrix decays on someone else's schedule.

A source build also pins exact point releases, so 4.4.18 is distinguishable from
4.4.0 when a bug report arrives.

### Wiring the matrix

Everything in the repository invokes the interpreter as bare `bash`, resolved
through `PATH` — the "no hardcoded absolute interpreter path" rule above. That
is what makes this cheap: a matrix job prepends its built Bash to `PATH` and
runs `tests/run portable` unmodified. No test needs to know it is running under
a non-default interpreter, and the gate prints `bash --version` so the job
output records which one.

The floor job and the newest job carry the most weight. 4.4 catches use of
anything above the declared minimum, including the 5.2 subscript rule above,
which nothing else can enforce. The newest Bash catches upstream drift, which
always arrives from the top of the range.

Practical notes:

- Cache the built interpreters keyed by exact version. The build is a minute or
  two and then never runs again until a version is added.
- Pin the tarball `sha256`. CI downloads these and runs a compiler over them.
- **Verify that 4.4 still compiles on the runner's toolchain before relying on
  this.** GCC 14 and Clang 15 promoted implicit function declarations to errors,
  which breaks many pre-2017 autoconf packages; `ubuntu-24.04` is still on GCC
  13, so 4.4 is expected to build, possibly with warnings. If it needs a
  `CFLAGS` relaxation, record that in the install script rather than dropping
  the job. This has not been verified yet — treat it as the first thing the
  matrix work must establish.
- ShellCheck is version-independent. Run it once in the existing gate, not in
  every matrix job.
- The matrix is Linux-only, and that is correct: it varies Bash, not the OS.
  macOS-specific behavior stays covered by the existing OS matrix, which also
  supplies the newest-Bash end of the range through Homebrew.

The guarantee is still one-sided: the matrix proves jailbox works at or above
4.4, not that it fails cleanly below. That direction is the guard's job, tested
with `/bin/bash` on macOS as a real 3.2 interpreter and with `dash` for the
non-Bash path.

Run `tests/run portable`. Also run the runtime and editor gates on macOS once
after the shebang change: no test asserts anything about the interpreter, but
every host module now executes under a different one than before.

## Non-goals

- No bundled Bash binaries.
- No automatic Homebrew or Bash installation.
- No login-shell changes.
- No zsh implementation or separate macOS code path.
- No `JAILBOX_BASH` override. `PATH` is the standard mechanism for selecting an
  interpreter and covers every case an override would. Add one later only if a
  concrete user cannot use `PATH`; it costs a re-exec and a loop guard.

## Rejected: portable launcher split

An earlier draft replaced the entrypoint with a POSIX `sh` launcher that probed
candidate interpreters and exec'd a separate installed implementation file. It
was rejected as disproportionate.

It required re-implementing symlink resolution in POSIX `sh` without
`readlink -f`, changes to install, update, uninstall, streamed-release
packaging, and the `$BIN_DIR` symlink relationship, plus a version probe forking
once per candidate on every invocation. All of that bought one thing the shebang
does not: a clear error for a user whose `PATH` Bash is old. The guard delivers
the same error for a two-line cost, because `#!/usr/bin/env bash` already
resolves the interpreter correctly for everyone who has one installed.
