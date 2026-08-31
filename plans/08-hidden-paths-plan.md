# 8. `HIDDEN_PATHS` — mask existing project content

## Goal

Add a project-path policy for content that the development container must not
access. Pass each validated container path to Podman's native
`--security-opt mask=...` policy so the original host content is inaccessible
inside the container.

This is runtime content hiding, not protection for paths that do not exist and
not protection during development-image builds.

## Sequence

Order 8.0. Requires `01-protected-path-policy-plan.md` for project-relative path
validation through `check_project_mount_path` and for trusted automatic
overlays, `04-config-digest-plan.md` for
automatic public-key coverage, and `07-writable-paths-plan.md` for the complete
project-path precedence model.

## Configuration

`HIDDEN_PATHS` is a comma-separated array in the strict config data format:

```conf
HIDDEN_PATHS=.env,secrets,config/credentials.json
```

An empty value is valid. No Bash-array syntax is accepted.

Each entry must:

- be a non-empty project-relative path;
- pass plan 1.0's shared lexical validation, including no `.`, `..`, colon, or
  trailing slash;
- exist before launch;
- have no symlink component below the canonical project root;
- resolve canonically beneath the canonical project root; and
- be unique within `HIDDEN_PATHS`.

Use the same lexical, symlink, canonical-containment, and canonical-project-root
rules as `READONLY_PATHS`. Paths from an external selected config remain
relative to `$PROJECT_DIR`. Reuse plan 1.0's low-level helpers and add only the
hidden policy's overlap and mask-construction decisions on top. Implement
`check_hidden_path` as a policy-specific wrapper around
`check_project_mount_path`, not around `check_readonly_path`.

Plan 1.0 owns colon rejection for every project path placed in a
colon-delimited Podman argument; Podman's mask option has the same delimiter.
Reject missing entries: this policy deliberately makes no promise that masking
an absent destination reserves its name against later creation. Only existing
regular files and directories are valid. Reject FIFOs, Unix sockets, character
and block devices, and every other special file, whose portable masking behavior
is outside this plan's supported contract. Do not follow or mask symlinks.

## Visible behavior

For each validated entry, construct its absolute path at the container's
project mountpoint and include it in Podman's native mask policy:

```text
--security-opt mask=/container/project/.env:/container/project/secrets
```

The original path cannot be accessed inside the container. Do not promise that
it appears as an empty file or directory, or that applications receive a
particular error code: those details belong to Podman and the OCI runtime. The
pathname may remain inferable from project configuration, parent-directory
metadata, errors, or other files.

Host content remains unchanged. Changes elsewhere in the project must not
reveal the content through the masked pathname.

Masking is pathname-scoped, not content- or inode-scoped. A pre-existing
hardlink to a masked regular file remains readable through its other pathname,
as does an ordinary copy elsewhere in the project. Document this alongside the
build-time boundary: callers must hide every reachable path containing the
secret, and jailbox does not discover aliases or copies.

## Podman capability and construction

Use `--security-opt mask=...`; do not synthesize empty bind sources, tmpfs
mounts, FUSE filesystems, or project placeholders.

Build one colon-separated mask value from fully validated container paths. No
configured value can inject another path because lexical validation rejects
colons before option construction. Pass the complete option as one quoted Bash
array element and never evaluate or word-split it.

Masking creates mounts inside the container's mount namespace. Its promise that
host content and host path visibility remain unchanged therefore requires
private bind propagation. When this plan lands, make `rprivate` explicit on the
project base bind and every project-path overlay rather than relying on Podman's
default. Never use `shared` or `rshared` propagation for these mounts: a mask or
another nested mount must not propagate back to the host. This intentionally
changes the spelling of the mount arguments established by plan 7 while
preserving their read/write and SELinux `Z` semantics.

The versioned Podman 4.0 manual documents native `mask=` support, which is enough
to show that this plan does not raise jailbox's existing 4.0 floor; it does not
establish which earlier release first introduced the option. Recording and
enforcing the currently unenforced general minimum, including confirmation from
release notes before assigning introduction versions, remains the work
identified by `supported-versions.md`, not a new feature probe in this plan.
`HIDDEN_PATHS` does bring a feature covered by that floor onto the non-egress
launch path for the first time. Until the general floor is enforced, an older
Podman may therefore fail only when this setting is used. If Podman rejects the
option, container creation fails normally. Do not probe by creating a separate
container, silently fall back to empty bind mounts, or retry launch without the
masks.

## Precedence and overlap

The policy precedence is:

```text
hidden mask > protected read-only overlay > writable lane > project base
```

Podman/OCI masking must be applied to the container after its project mounts are
assembled, so a mask is the final policy for that path. Prove this behavior in
the runtime gate rather than relying only on argument ordering.

Validate overlaps before constructing the option:

- exact duplicates between `HIDDEN_PATHS` and `READONLY_PATHS` are accepted and
  collapse to the hidden policy;
- hiding the default config, selected in-project config, or exact used
  Containerfile is accepted; hidden is stronger than read-only after the host
  has consumed those inputs;
- a hidden path nested beneath a writable or read-only path is accepted and the
  mask wins;
- a writable or read-only path nested beneath a hidden directory must not be
  re-exposed; omit the shadowed child mount after validating it; and
- duplicate or overlapping `HIDDEN_PATHS` entries are rejected when one hides
  an ancestor of another, because the descendant adds no policy and makes the
  effective set harder to audit.

Runtime validation must understand that a hidden automatic trusted input is
stronger than a readable read-only overlay. Do not report it as a missing
read-only mount.

## Build-time limitation

`HIDDEN_PATHS` applies only to the running development container. jailbox builds
the development image before the container mask exists. A Containerfile can
still read or copy a hidden path when it is inside `DEV_BUILD_CONTEXT`.

Document this prominently. Secrets must also be excluded from build context via
`.containerignore` or `.dockerignore`, or kept outside the build context. Do not
claim that runtime masking repairs a secret already copied into an image layer,
build cache, generated artifact, Git history, log, or another project file.

Build-context filtering or validation is separate work. This plan does not edit
ignore files automatically.

## Implementation

- Add `HIDDEN_PATHS` to `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`, parser
  assignment, the supported-settings header, documentation, and
  `tests/unit/public-api-diff.sh` expectations.
- Add lexical validation in `host/common.sh`. Add semantic existence, type,
  symlink, and containment validation alongside the project path-policy helpers
  established by plan 1.0; do not duplicate their containment logic.
- Declare the validated hidden-path array and final security-option argument in
  `host/container-runtime.sh`, which owns container invocation state.
- Validate every hidden entry before image, network, credential, volume, or
  container side effects.
- Resolve overlap with writable and protected paths, translate the remaining
  entries to container-absolute paths, and build the single quoted mask option.
- Add explicit `rprivate` propagation to the project base, writable-lane, and
  protected-overlay bind arguments in every mount mode. Extend launch-state
  assertions so a missing or non-private propagation option is an internal
  error before container creation.
- Emit the native mask option in the container invocation; an option error is a
  launch failure and must never trigger an unmasked retry.
- Extend `assert_container_launch_state` to require the initialized mask option
  whenever the effective hidden set is non-empty.
- Extend runtime validation to prove original content is inaccessible and to
  treat hidden automatic inputs as satisfying the stronger policy.

No new project-state directory or cleanup behavior is introduced. `stop` and
`--clean` remain unchanged.

`HIDDEN_PATHS` participates in the configuration digest automatically through
`CONFIG_ARRAY_KEYS`. Preserve declared order in the digest, following plan 4.0's
conservative default for path arrays.

Review `scripts/public-api-diff.sh`: adding `HIDDEN_PATHS` is a minor public-API
change before 1.0.

## Documentation

Document:

- the difference between read-only and inaccessible masked paths;
- that hidden paths must already exist;
- that access errors and path visibility are controlled by Podman and the OCI
  runtime;
- precedence over writable and protected paths;
- the runtime-only boundary and build-context limitation;
- the pathname-scoped boundary, including readable hardlinks and copies at
  other unmasked paths;
- that the host files remain unchanged; and
- that secrets are safest outside both the project tree and build context.

Do not describe hidden paths as cryptographically erased, undetectable, or safe
after their contents have been copied elsewhere.

## Tests

Parser and validation:

- empty and multiple `HIDDEN_PATHS` values parse correctly;
- absolute, empty, dot-segment, colon-containing, trailing-slash, duplicate,
  missing, outside, symlinked, FIFO, socket, device, and other special-file
  entries are rejected;
- regular files and directories are accepted;
- project roots reached through a host symlink prefix remain valid; and
- invalid entries fail before launch side effects exist.

Option construction:

- every entry becomes the expected absolute container path;
- multiple paths form one quoted `--security-opt mask=...` argument;
- grammar-valid glob characters such as `*` and `?`, and option-like path
  segments remain literal; whitespace and bracket characters retain the strict
  configuration grammar's existing rejection and are not accepted by this
  feature;
- no bind source, project placeholder, or new runtime-state directory is
  created;
- the project base and every project-path overlay explicitly use `rprivate`
  propagation; no `shared` or `rshared` project bind can reach container
  creation;
- an option failure is returned without an unmasked retry.

Runtime policy:

- a masked file inside the bind-mounted project cannot be read or written;
- a masked directory inside the bind-mounted project cannot have its original
  entries listed, read, or written;
- both file and directory masks remain effective with jailbox's read-only
  container root filesystem enabled;
- host files and directories remain unchanged after container access attempts;
- the host path remains mounted and visible with its original content while the
  corresponding container path is masked, proving that the container-side mask
  did not propagate to the host;
- a pre-existing hardlink and an ordinary copy at unmasked paths remain
  readable, explicitly demonstrating the pathname-scoped limitation;
- masks win over exact and nested read-only or writable overlaps;
- a masked automatic config or Containerfile satisfies the stronger runtime
  policy without a false validation warning;
- child mounts do not re-expose content beneath a masked directory;
- `podman inspect` records the intended mask policy; and
- changing `HIDDEN_PATHS` causes `exec` and `shell` to reject a stale sandbox via
  the configuration digest.

Add focused parser, path-validation, overlap, and option-construction tests at
the unit layer. Put real content-isolation, OCI-runtime behavior, and precedence
assertions in the runtime suite.

Extend plan 7's minimal real-Podman nested-mount fixture with a mask over a bound
path and prove that the mask wins without a child mount re-exposing content.
This shared fixture de-risks both precedence contracts directly; do not treat
CLI argument order or inspect output alone as proof of effective isolation.
Update plan 7's exact empty-allowlist mount-argument expectation from `:Z` to
`:Z,rprivate` when this plan lands; the order-7 test protects compatibility at
that stage, while order 8 deliberately strengthens the argument spelling.

Run `tests/run portable` and `tests/run runtime` wherever Podman is available.
Run `tests/run editor` only if implementation changes editor integration beyond
the project view already covered by runtime masking.

## Non-goals

- Protecting or reserving a path that does not exist.
- Hiding pathnames or file types.
- Filtering `DEV_BUILD_CONTEXT` or editing ignore files.
- Removing secrets already copied into images, caches, Git history, logs, or
  other files.
- Passing secrets into the container through a replacement mechanism.
- Maintaining an alternative masking implementation for unsupported runtimes.
