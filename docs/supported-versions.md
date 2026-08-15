# Supported versions

## What this document is for

jailbox depends on external software — Bash, Podman, an editor, and whatever
base image a project brings. This document records the **minimum version** of
each, and the reasoning that produced it.

A floor is not a pin. `versions.env` holds pins: the exact versions jailbox is
tested against, bumped forward by the canary workflow when a run goes green. A
floor is the opposite kind of statement — the oldest version jailbox accepts —
and it must never be rewritten by automation. The two live apart deliberately.

## The pattern

Every floor in this document follows the same three steps. Apply it to any new
dependency.

1. **Derive a candidate from features.** List what jailbox actually uses and
   the version that introduced each. The candidate is the highest of those,
   not what is newest or what merely feels safe.
2. **Guard it early, with a clear message.** Check before any expensive or
   partial work — before builds, before network setup, before the first
   container starts. The error names the requirement and how to satisfy it.
3. **Test the floor.** A declared minimum that CI never exercises is an
   assumption. If the feature-derived candidate cannot be tested reasonably,
   raise the supported floor to the oldest version that can. Test that floor
   and the newest; add intermediate versions where behavior changes matter.

CI testability is therefore a legitimate constraint, but not an automated
ratchet. Do not raise a floor merely because a runner changed or a version is
old. Confirm that a conventional pinned setup is impractical, record the reason,
and choose the oldest reliably testable replacement. Excluding a user still
needs an explicit justification.

Step 2 is what separates a supported version from a hopeful one. Without a
guard, an unsupported version does not fail — it half-works, and fails later
somewhere unrelated.

## Bash — 4.4

Derived in [modern-bash-runtime-plan.md](modern-bash-runtime-plan.md), which
holds the full reasoning and implementation plan.

| Feature | Introduced |
| --- | --- |
| Associative arrays, `mapfile` | 4.0 |
| Namerefs (`local -n`) | 4.3 |
| `"${a[@]}"` on an empty array under `set -u` | **4.4** |

The guard at the top of `jailbox` enforces the floor before loading host
modules or project configuration. CI runs the complete portable gate with
Bash 4.4 and the current runner Bash; macOS CI also verifies that its system
Bash 3.2 receives the documented error.

## Podman — 4.0, not yet enforced

**jailbox already requires Podman 4.0 and does not say so.** This is the most
urgent gap in this document.

| Feature | Introduced | Used at |
| --- | --- | --- |
| `--replace` | 2.x | `container-runtime.sh`, `network.sh` |
| `--userns=keep-id` | 2.x | `container-runtime.sh` |
| `podman network exists`, `volume exists` | 3.x | `network.sh`, `container-runtime.sh` |
| Internal networks (`--internal`) | 3.x | `network.sh` |
| **`--network <name>:ip=<addr>`** | **4.0** | `network.sh:80` |
| Two `--network` flags on one `run` | 4.0 | `network.sh:79-80` |

The binding constraint is the per-network options syntax. Before Podman 4.0 a
static address was `--ip`, and a named network could not carry options this way.

Confirm the 4.0 attribution against Podman's release notes before enforcing it.
The usage is verified in this repository; the version each flag landed in is
not, and the whole point of the pattern is that the number is derived rather
than assumed.

### Why this one matters more than it looks

The 4.0-only syntax is on the **egress path**, reached only when `EGRESS_ALLOW`
is set. A user on Podman 3.4 therefore does not get a clean failure. Basic
launches work. Then, the first time they configure egress filtering, proxy
startup dies on a flag parse error — after the dev image build, after the
wrapper image build, in a code path they will not connect to their Podman
version.

Partial function is worse than refusal. That is the case for a guard rather
than a note in the README.

### Where the check goes

`host/preflight.sh` currently calls `require_command podman`, which tests
presence only. It should test version too, in `host_preflight`, before
`build_or_select_dev_image` — the same position the Bash guard occupies
relative to config loading. `podman version --format '{{.Client.Version}}'`
gives a parseable value.

Skip the check for `--clean`, `doctor`, and `ssh-config`, matching how
`host_preflight` already short-circuits those paths.

### The Podman ceiling

Podman 5.0 replaced slirp4netns with pasta as the default rootless network
backend, changing port-forwarding and host-connectivity behavior. jailbox
forwards an SSH port to `127.0.0.1` and depends on that behavior directly, so
Podman is a dependency where the **newest** version deserves a test job as much
as the oldest. This is a testing obligation, not a floor.

## Dev image glibc — 2.28, warn only

The dev image is user-supplied, which makes it the likeliest source of a
confusing failure.

VSCodium and VS Code Remote SSH install a server component into the container.
Modern releases require **glibc 2.28 or newer**; VS Code 1.86 dropped support
for older. A dev image based on Debian 9, CentOS 7, or Ubuntu 16.04 completes
every jailbox step and then fails inside the editor's own bootstrap, with an
error that does not mention glibc.

This is a warning, not a hard failure: jailbox itself works, only the editor
workflow breaks, and `jailbox ssh-config` remains useful.

The pattern already exists. `warn_if_alpine_dev_image_with_vscode` in
`host/dev-image.sh:87` probes `/etc/os-release` and warns when a musl-based
image is paired with VS Code. A glibc check belongs beside it, using the same
probe, and should extend to VSCodium rather than only `code`.

`README.md` "Project image requirements" documents the shell and package
manager a dev image must provide. glibc belongs in that list.

## macOS — 12.3, or coreutils

`host/preflight.sh` requires `realpath`, which macOS did not ship before 12.3.
The same release added `readlink -f`. Either declare macOS 12.3 the minimum, or
declare coreutils a prerequisite and document it — but pick one, because today
the dependency is silent.

Reconcile `README.md` while doing so: the Requirements section says "**Linux**
with **Podman**", which contradicts jailbox's macOS support and the Bash plan
that exists to serve it.

## Deliberately unversioned

- **OpenSSH.** jailbox uses `-F`, `ConnectTimeout`, and ed25519 keys, all
  available since 2014. No realistic host fails this.
- **git.** Optional, already guarded by `command -v` before the gitconfig mount.
- **`cksum`, `sha256sum`, `shasum`.** POSIX or already behind a fallback chain
  in `host/project-id.sh`.

Recording these is part of the point: an unversioned dependency should be a
decision, not an omission.

## Testing floors

Floors are claims, and claims need evidence.

- **Bash:** build the minimum version from source and run the portable gate
  under it and the current runner Bash.
- **Podman:** harder, since Podman is not a self-contained build. Testing the
  candidate likely means a runner image or a package archive. If 4.0 cannot be
  exercised reasonably, choose and document the oldest version CI can test
  instead of claiming an untested floor.
- **glibc:** a probe test against a known-old base image, asserting the warning
  fires. Cheap, because it only needs the image pulled, not run.

Where a candidate floor cannot be tested reasonably, raise the supported floor
and keep the guard aligned with it. A clean rejection below a tested floor is
more honest than an unverified compatibility claim.

## Where the numbers live

Each floor is defined once, in the code that enforces it — the Bash guard in
`jailbox`, the Podman check in `host/preflight.sh`. Documentation restates
them; the code is the source of truth.

None of them belong in `versions.env`. The canary workflow rewrites that file
on green, `scripts/resolve-latest-versions.sh` reports its entries as drifting
behind upstream, and `scripts/gen-tested-matrix.sh` renders them as tested
configurations. All three behaviors are correct for pins and wrong for floors.
