# Modern Bash host runtime

## Goal

Require Bash 4.4 or newer for jailbox host orchestration, as a documented
prerequisite enforced by a version check. On macOS, users install modern Bash
through Homebrew. jailbox does not bundle Bash and does not change the user's
login shell.

This requirement must land before any feature begins using associative arrays,
namerefs, `mapfile`, or other syntax unavailable in macOS Bash 3.2.

### Minimum version choice

The feature-derived floor is the oldest Bash that provides what jailbox needs
to stay clean. The supported floor must also be practical to exercise in CI:
jailbox does not claim support for an interpreter it cannot test reasonably.
It is not set by what is newest. Excluding a user remains a cost paid for a
named feature or a concrete testing constraint:

| Feature | Introduced | Why jailbox wants it |
| --- | --- | --- |
| Associative arrays, `mapfile` | 4.0 | Replaces parallel indexed arrays and `while read` loops |
| Namerefs (`local -n`) | 4.3 | Lets helpers write to a caller's array without globals |
| `"${a[@]}"` on an empty array under `set -u` | **4.4** | Removes the `${array[@]+"${array[@]}"}` idiom repo-wide |

The binding constraint is 4.4, and it is the least glamorous of the three. Bash
4.4 stopped throwing an unbound-variable error when `${a[@]}` or `${a[*]}`
expands an array with no assigned elements under `nounset` (bash `CHANGES`, 4.4
series). That is what retires the guard form `AGENTS.md:45-47` currently mandates
for every possibly-empty array — `EGRESS_ALLOW`, `READONLY_EXTRA`,
`READONLY_MOUNTS`, `GITCONFIG_MOUNT`, `SSH_SESSION_ENV`, and `CONFIG_SEEN_KEYS`,
across thirteen expansion sites in `host/` and `tests/`. Measured by
maintainability, that single change is worth more than namerefs.

Two things about that set were verified rather than assumed. `ROOTFS_FLAG` is
*not* in it despite looking like it: `configure_runtime_mounts` assigns it
unconditionally, so it is never empty and already expands bare. And every array
that does use the guard form is *declared* empty — by `apply_config_defaults`
or at the top of `jailbox` — which is exactly the case 4.4 fixed. No site
expands a never-declared array, so the removals do not additionally depend on
how a given Bash treats an unset variable under `nounset`.

So **4.4 is the candidate floor**. Nothing jailbox needs lives above it. It
becomes the supported floor only after the pinned 4.4 build and complete
portable gate pass in CI. If a conventional source build is not viable on the
runner toolchain, use the oldest later Bash series that can be tested reliably
and update the guard, matrix, and documentation together before landing.

If that changes the floor, rewrite the guard rather than mechanically replacing
version numbers. An `N.0` floor needs only the POSIX-parseable major-version
check, for example `[ "${BASH_VERSINFO:-0}" -lt 5 ]` for Bash 5.0. The split
major/minor checks below are needed only for an `N.M` floor where `M` is greater
than zero; in that case they ensure a non-Bash shell exits before reaching the
array subscript. Update the error text and the explanation with the guard.

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
safe under both semantics, with focused regression tests run across the version
matrix.
`shopt -s assoc_expand_once` is not available as an escape hatch, since it
arrived in 5.0 and the floor is 4.4.

Treat it as a coding rule: never place an unquoted, non-literal subscript in an
arithmetic context. Add regression cases with adversarial, configuration-derived
keys; running those cases on both sides of the 5.2 behavior change is what
enforces the rule. The matrix alone cannot detect a path the tests do not cover.

### Moving the floor later

The floor moves when a named feature justifies it or when the existing floor can
no longer be exercised reasonably in CI. It does not move on a schedule, merely
because a version is old, or automatically when a runner image changes. Raising
it is a user-facing exclusion, so record the specific feature or CI limitation
and select the oldest practical replacement rather than jumping to newest.

CI testability constrains the floor but does not automate it. The Bash
compatibility matrix proves the chosen floor; `versions.env` and canary updates
must never rewrite the requirement.

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

Five areas of change, listed as six commits-worth of work in the change set
below. There is no launcher, no second installed file, and no change to
packaging or the install layout.

### 1. Resolve Bash through `PATH`

Change the shebang of both `jailbox` and `install.sh` from `#!/bin/bash` to
`#!/usr/bin/env bash`.

On macOS, `#!/bin/bash` is hard-wired to the system 3.2 even when a modern Bash
is installed. `env bash` picks up Homebrew's Bash for anyone who ran
`brew install bash`, and equally serves MacPorts, Nix, and managed workstations,
because they all work by putting their `bin` directory on `PATH`. On Linux it is
a no-op for system Bash and lets a user-installed newer Bash win.

`scripts/lint.sh` already uses this form; the rest of the repository does not.

#### Why `install.sh` changes too

`install.sh` keeps its Bash 3.2 *syntax* constraint — it runs before a modern
Bash is necessarily present — but that is a constraint on what it may contain,
not a reason to pin the interpreter path. On NixOS and Guix there is no
`/bin/bash` at all, only `/bin/sh`, so `#!/bin/bash` makes the installer fail
with a "no such file or directory" before jailbox exists to report anything.
That directly contradicts the Nix case section 1 relies on. `env bash` costs
nothing on a host that has only Bash 3.2: it resolves to that same 3.2, which
`install.sh` is written to tolerate.

The consequence is that Bash 3.2 installer coverage stops being a free
side effect of the shebang on macOS and has to be asked for explicitly. Section
4 below does exactly that.

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

Hardcoded `/bin/bash` is permitted only in macOS portable tests that
deliberately exercise the system Bash 3.2 interpreter. Production code,
ordinary script callers, README, and contributor documentation must continue
to resolve `bash` through `PATH`.

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

#### The second `if` needs a rejection fixture the version matrix cannot supply

The two subtleties above are not equally covered.

Dropping the `-eq 4` *is* caught. It would make the second test reject any Bash
with a minor version below 4, and the 5.0 and 5.1 matrix entries run the gate,
which runs `jailbox` — so those jobs go red immediately. The matrix is the test
for that mistake, and no synthetic acceptance case is needed for it.

The gap is the other direction. Nothing in the matrix executes the second
statement's *true* branch: every built interpreter is at or above the floor, and
macOS Bash 3.2 exits inside the first `if`, so no CI entry ever runs a Bash in
the 4.0–4.3 range. Delete the second `if` entirely and 4.0 through 4.3 are
silently accepted below the declared floor, with every job still green.

Close that with a rejection fixture: build one 4.3 alongside the supported
versions and assert that `jailbox` refuses it with the floor message. It is a
fixture, not a matrix entry — it never runs the gate, only the guard. A stubbed
version tuple exercised as a unit test is a reasonable cheaper substitute if the
extra cached build is unwelcome, but it tests the comparison rather than the
interpreter.

The guard is a hard failure. There is no warning variant and no grace period —
there are no installs to protect, and a two-state guard would mean two versions
of this snippet to write, test, and keep consistent.

The guard is still worth having with no users. Its purpose is not migration; it
is to give the *first* user without Bash 4.4 a clear instruction instead of a
parse error or a confusing failure deep inside a Podman call.

### 3. Give the macOS portable runner a modern Bash

`tests/ci/setup-portable.sh` installs `coreutils` and `shellcheck` on Darwin and
prepends `gnubin` to `PATH`. It does not install a Bash, and the macOS runner's
`PATH` Bash is the system 3.2. The shebang change turns that omission into two
failures in the *existing* macOS portable job:

- `tests/portable/smoke.sh` runs the installed `"$tmp/bin/jailbox" --help`
  directly. Under `#!/usr/bin/env bash` that now resolves to 3.2, hits the new
  guard, and exits 1.
- The syntax check runs `bash -n host/*.sh` under the `PATH` Bash. Under 3.2
  that rejects the first `declare -A` in `host/` — the exact syntax the floor
  exists to permit.

So `brew install bash` and a `prepend_path "$(brew --prefix bash)/bin"` belong
in the Darwin branch of `setup-portable.sh`, beside the existing coreutils
handling and for the same reason: the suite depends on a modern userland.

Then assert it. `verify_portable_tools` should check that the `PATH` Bash is at
or above the floor and fail loudly if it is not. Without that assertion, a
future runner-image change silently downgrades the macOS portable job to
re-testing Bash 3.2 while still reporting green — which is the failure mode this
whole plan is trying to remove.

### 4. Test the supported Bash range

Launch the complete portable gate with Bash 4.4, 5.0, 5.1, 5.2, 5.3, and the
runner's own Bash. Every Bash compatibility-matrix entry runs exactly the same
command:

```sh
tests/run portable
```

Do not split ShellCheck, generated-file checks, unit tests, or distribution
tests into version-specific subsets: invoking the portable gate should mean the
same thing everywhere.

The selected matrix Bash runs the gate, its Bash-invoked test suites, and both
installed entry points — `jailbox` and `install.sh` now resolve through the
matrix `PATH` along with everything else.

Bash 3.2 installer coverage is no longer a side effect of `install.sh`'s
shebang, so the macOS portable job has to ask for it directly — and it has to
ask on *every* installer invocation, not one. `tests/portable/smoke.sh` executes
the installer four times, each as a direct `./install.sh` call that follows the
shebang:

| Invocation | Function |
| --- | --- |
| Initial install | `smoke_install_update_uninstall` |
| Re-run over a managed install (update) | `smoke_install_update_uninstall` |
| `--uninstall`, from the *installed copy* | `smoke_install_update_uninstall` |
| Re-run over an unmanaged directory (refusal) | `refuse_unmanaged_update_target` |

Prefixing only the first would leave update, uninstall, and the refusal path
running under modern Bash — which is precisely where a 3.2 incompatibility in
`install.sh` is most likely to hide, since those paths do the directory
inspection and removal work. On macOS, all four run as `/bin/bash ./install.sh`
(and `/bin/bash "$tmp/share/jailbox/install.sh" --uninstall` for the installed
copy). The "hardcoded `/bin/bash` in macOS portable tests only" rule above
exists to allow exactly this.

### 5. Document the prerequisite

Update README prerequisites, `AGENTS.md` shell compatibility rules, and
`CONTRIBUTING.md`.

The `AGENTS.md` edit is `AGENTS.md:43-47`, and it is two rules, not one. The
first — "must work with macOS Bash 3.2 … avoid namerefs and `mapfile`" — is
what this plan replaces. The second — use `${array[*]-}` rather than
`${#array[@]}` to test an array whose valid elements cannot be empty — is
unrelated to the floor and must survive the rewrite. Retire the first, keep the
second, and add the narrower 3.2 rule that replaces it: `jailbox` and
`install.sh` stay 3.2-parseable, everything else may use 4.4.

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
The repository-wide policy for candidates that cannot be tested reasonably is
documented in [`docs/supported-versions.md`](supported-versions.md).

## The one invariant, and how it is enforced

The `jailbox` entrypoint and `install.sh` must stay parseable by Bash 3.2.
`jailbox` needs that compatibility so a user without modern Bash reaches the
guard instead of a raw parse error. `install.sh` runs before a compatible host
runtime is necessarily installed. `host/*.sh` are under no such constraint:
they carry no shebang, are only ever sourced, and are parsed by the
already-running interpreter after the guard has passed.

This is enforced, not left to convention. The macOS portable job uses the
system `/bin/bash` as a real Bash 3.2 parser oracle. In
`tests/portable/smoke.sh`:

- On macOS, first verify that `/bin/bash` identifies itself as Bash 3.2, then
  run `/bin/bash -n jailbox install.sh`; both files must parse successfully.
- `bash -n` for `host/*.sh` and everything else, under the `PATH` Bash — which
  section 3 guarantees is at or above the floor on every runner, so this check
  actually accepts the syntax the floor permits.

Do not build or emulate Bash 3.2 on Linux. Its relevance is specifically the
macOS system interpreter, and the existing macOS portable job tests that real
environment. Linux jobs test only supported Bash versions. Every CI entry still
invokes the same public command, `tests/run portable`; the 3.2 parser assertion
is a platform-specific check within that gate.

A contributor who puts Bash 4.4 syntax in `jailbox` itself fails the portable
gate on macOS. The consequence of the invariant breaking is also mild — a user
who already lacks Bash 4.4 sees an ugly error instead of a clear one — so the
enforcement is proportionate.

## Compatibility policy

- `host/` targets Bash 4.4 or newer.
- `jailbox` targets Bash 4.4 at runtime but must remain Bash 3.2-parseable.
- `install.sh` stays Bash 3.2-compatible *in syntax*, while resolving its
  interpreter through `PATH` like everything else. It runs before modern Bash is
  necessarily present, so it must be able to install jailbox and let the guard
  report the missing runtime — but it must also run on a host with no
  `/bin/bash` at all.
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

1. `#!/usr/bin/env bash` in `jailbox` and `install.sh`, plus the version guard.
2. `brew install bash` and a `PATH` prepend in the Darwin branch of
   `tests/ci/setup-portable.sh`, with a floor assertion in
   `verify_portable_tools`. This is a prerequisite for the shebang change, not a
   follow-up: without it the existing macOS portable job goes red.
3. Split the syntax checks in `tests/portable/smoke.sh`: use the required Bash
   3.2 parser on macOS for `jailbox` and `install.sh`, and the `PATH` Bash for
   all other Bash files. In the same file, prefix **all four** installer
   invocations with `/bin/bash` on macOS — install, update, installed-copy
   uninstall, and the unmanaged-directory refusal — to keep the Bash 3.2
   installer coverage the shebang change gives up.
4. Add the supported Bash-version setup and Linux Bash compatibility matrix;
   every entry, including the existing macOS portable job, runs the complete
   `tests/run portable` gate unchanged. Make the gate print `bash --version` on
   entry, so every job records which interpreter it actually used.
5. Add a Bash 4.3 rejection fixture for the guard's minor-version branch, the
   one case the matrix structurally cannot reach.
6. Update `AGENTS.md`, README prerequisites, `CONTRIBUTING.md`, and the in-flight
   plans that still state a Bash 3.2 constraint.

Adopting Bash 4.4 features in `host/` should still be a separate commit, but for
dependency reasons rather than release safety: until the shebang change lands,
`declare -A` in a host module breaks jailbox on any macOS machine, including the
one it is being written on. Once the floor is in, the constraint is gone and
feature adoption proceeds normally.

The only sequencing risk left is a self-inflicted one. Changing the shebang
moves macOS portable-gate execution from Bash 3.2 to 5.x, which is where a
latent 3.2-era assumption in `host/` would surface. The existing macOS portable
job covers that transition across its own scope, without expanding runtime or
editor platform scope — but see the limit on what that scope is.

Within the landing commit itself, the macOS runner Bash install (section 3) must
precede or accompany the shebang change. Shipping the shebang alone turns the
macOS portable job red immediately, because that job's only Bash is the 3.2 the
guard is designed to reject.

### Limit of macOS CI coverage

The hosted macOS job runs only the portable gate. The runtime and editor gates
remain Linux-only because they require Podman container execution and, for the
editor gate, a graphical editor session.

Consequently, CI verifies Bash selection, Bash 3.2 parsing, unit behavior,
packaging, and installation on macOS, but does not verify a complete macOS
container launch or editor session.

The shebang change removes an interpreter mismatch rather than reducing one.
Today the macOS portable job resolves `bash` through `PATH` and direct
execution of `jailbox` selects `/bin/bash` — but both land on the same system
3.2, so the mismatch is invisible. Sections 1 and 3 together make `PATH` the
single selection mechanism *and* put a modern Bash on it, which is what turns
the macOS job into real coverage of the supported runtime instead of coverage
of the interpreter the guard rejects.

The macOS portable job is non-removable while these compatibility claims
remain: it is the only job that exercises the real system Bash 3.2 parser and
macOS interpreter selection.

If macOS is a supported runtime platform, perform one manual launch and editor
verification on macOS after this change. Otherwise, document macOS as a
portability and installation-test platform rather than a supported runtime.

## Tests

- The guard rejects Bash 3.2 with a clear error, invoked as
  `/bin/bash jailbox` on macOS.
- The guard rejects a non-Bash interpreter with the same error, tested with both
  `sh jailbox` and `dash jailbox`. This is the regression test for the split
  `if` statements; a merged condition fails here with "Bad substitution".
- On macOS, `/bin/bash` is verified as Bash 3.2 and both `jailbox` and
  `install.sh` parse under it.
- A modern Bash earlier on `PATH` than the system one is selected, and jailbox
  reaches normal argument handling.
- Invocation through the installed `$BIN_DIR` symlink still resolves `host/`.
  This existing behaviour in `resolve_script_path` is already covered by the
  install lifecycle and is unchanged by the shebang.
- The complete portable gate is launched unchanged with every supported Bash
  version in the matrix below and prints `bash --version` in its output, so both
  the selected interpreter and identical gate scope are recorded facts.
- On macOS, every installer invocation in the portable smoke — install, update,
  installed-copy uninstall, and the unmanaged-directory refusal — runs under
  `/bin/bash`, giving Bash 3.2 installer behavior coverage explicitly rather
  than as a side effect of a pinned shebang.
- The `PATH` Bash on every portable runner, macOS included, is at or above the
  floor. This is an assertion in `verify_portable_tools`, not an assumption: it
  is what stops a runner-image change from quietly reverting the macOS job to
  testing Bash 3.2.
- The guard rejects Bash 4.3 with the floor message. This is the one branch the
  version matrix structurally cannot reach; the `-eq 4` mistake in the other
  direction is already caught by the 5.0 and 5.1 matrix entries failing.
- The `${array[@]+"${array[@]}"}` removals behave identically on 4.4 and on the
  newest Bash. This is the change the floor was chosen to enable, so it is the
  one that most needs both ends of the range.

### Bash compatibility matrix

A declared floor of 4.4 is a claim about five releases — 4.4, 5.0, 5.1, 5.2, and
5.3 — and every one of them should be exercised. Supporting a version without
testing it is an assumption, and the whole point of deriving the floor from
features is that the resulting claim is honest.

The Bash compatibility matrix applies to the **portable gate only**. Every
entry runs all of it:
ShellCheck, generated-file checks, unit tests, the release tarball, and the
install lifecycle. Note what that does and does not vary: the lifecycle *runs*
in every entry, but on macOS one invocation is deliberately pinned to
`/bin/bash` for 3.2 coverage, so the installer interpreter is not varied across
the matrix the way `jailbox`'s is. It needs no Podman, GUI, or privileges, so it
is cheap to multiply. The runtime and editor gates stay on their existing jobs; they test
jailbox's interaction with the outside world, not the supported Bash range.

Build the supported interpreters from source on one current Linux runner. Do
not use old distro images. Do not build Bash 3.2 on Linux; the macOS portable
job uses the system `/bin/bash` for the only 3.2 compatibility claim.

| Bash | Source |
| --- | --- |
| 3.2 (parser only) | macOS system `/bin/bash` |
| 4.4.18 | `ftp.gnu.org/gnu/bash`, built |
| 5.0.18 | `ftp.gnu.org/gnu/bash`, built |
| 5.1.16 | `ftp.gnu.org/gnu/bash`, built |
| 5.2.37 | `ftp.gnu.org/gnu/bash`, built |
| 5.3.x | `ftp.gnu.org/gnu/bash`, built — resolve the exact point release when wiring |
| runner default | ubuntu runner and macOS Homebrew, via the existing gates |

5.3 is pinned and built like the rest rather than being left to the "runner
default" row. That row is drift detection, not coverage: it tracks whatever the
image happens to ship, and `ubuntu-24.04` currently ships 5.2, so leaning on it
for the top of the range would both duplicate the 5.2 entry and leave 5.3
untested.

Old base images look like the cheap option and are not:

- **They vary the wrong thing.** `ubuntu:18.04` brings not just Bash 4.4 but
  coreutils 8.28, an old `sed`, and ShellCheck 0.4.x. A red job would not say
  whether Bash 4.4 broke or ancient `realpath` did. `tests/ci/setup-portable.sh`
  already installs coreutils and prepends `gnubin` precisely because the suite
  depends on modern userland. One host with N interpreters changes exactly one
  variable, which is the entire point of the Bash compatibility matrix.
- **Distro Bash is patched Bash.** Debian's 5.2 is not vanilla 5.2. The floor is
  a claim about upstream 4.4, not about whatever Ubuntu 18.04 shipped and then
  backported into.
- **The images are EOL.** `ubuntu:18.04` and `debian:10` are already past end of
  life; depending on them means the Bash compatibility matrix decays on someone
  else's schedule.

A source build also pins exact point releases, so 4.4.18 is distinguishable from
4.4.0 when a bug report arrives.

### Wiring the Bash compatibility matrix

Everything in the repository invokes the interpreter as bare `bash`, resolved
through `PATH` — the "no hardcoded absolute interpreter path" rule above. That
is what makes this cheap: each Bash compatibility entry prepends its built Bash
to `PATH` and runs `tests/run portable` unmodified. No test needs to know it is
running under a non-default interpreter, and the gate prints `bash --version`
so the job output records which one. There is no reduced or special-case
command: the same public gate runs in every entry.

The floor entry and the newest entry carry the most weight. 4.4 catches use of
anything above the declared minimum, including the 5.2 subscript rule above,
which nothing else can enforce. The newest Bash catches upstream drift, which
always arrives from the top of the range.

Practical notes:

- Cache the built interpreters keyed by exact version. The build is a minute or
  two and then never runs again until a version is added.
- Pin the tarball `sha256`. CI downloads these and runs a compiler over them.
- **Verify that 4.4 still compiles on the runner's toolchain before fixing the
  floor at 4.4.** Use the normal upstream source-and-patch build with ordinary
  compiler settings. A small, maintainable build adjustment is acceptable, but
  do not accumulate compatibility patches or fragile compiler workarounds just
  to preserve the candidate floor. If 4.4 is not reasonably buildable, select
  the oldest later series that is, then update the guard, matrix, and both
  version-policy documents to that floor. This is the first implementation
  task.

  Expect the specific hazard rather than discovering it: GCC 14 turned implicit
  function declarations into errors, which is what breaks pre-5.1 Bash builds on
  current toolchains. Decide up front whether relaxing that one diagnostic
  counts as "ordinary compiler settings" — the position here is that a single
  documented `CFLAGS` entry does, and that anything requiring source patches
  does not. Settling it before the build is attempted keeps the floor decision
  from being made by whoever is debugging CI that day.
- Run the complete portable gate in every Bash compatibility entry even where
  an individual component, such as ShellCheck, is not Bash-version-sensitive.
  Consistency is worth the small duplicated cost.
- The Bash compatibility matrix is Linux-only, and that is correct: it varies
  Bash, not the OS. macOS-specific behavior stays covered by the existing OS
  matrix. Note that the macOS job no longer supplies the top of the Bash range:
  Homebrew's Bash is there so the gate runs on a supported interpreter at all,
  while the range itself is pinned and built on Linux.

The Linux Bash compatibility matrix proves the complete portable gate works
across the supported Bash range — not the Podman or editor paths, which no
matrix entry touches. The macOS system Bash proves that `jailbox` reaches its
guard and that `install.sh` remains parseable before modern Bash is installed,
and the pinned `/bin/bash` installer calls exercise installer behavior under
3.2. `dash` covers the non-Bash invocation path. The 4.3 fixture covers the
rejection branch no built interpreter reaches.

Runtime and editor coverage remains unchanged, because this plan changes the
host interpreter contract, not the supported Podman or editor platforms.

## Non-goals

- No bundled Bash binaries.
- No automatic Homebrew or Bash installation *on a user's machine*. CI installs
  its own interpreters — that is test setup, not a runtime behavior, and
  `jailbox` never installs or offers to install a Bash.
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
