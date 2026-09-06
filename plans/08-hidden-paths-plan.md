# 8. Hidden project paths

## Goal

Mask selected project subpaths without weakening writable/read-only policy or
the build-context boundary.

## Sequence

Requires `07-writable-paths-plan.md`,
`03.1-environment-only-configuration-plan.md`,
`03.2.02-configuration-digest-plan.md`,
`03.2.06-constrained-up-plan.md`, and
`01-protected-path-policy-plan.md` for path classification.

## Policy

Declare `HIDDEN_PATHS` as a canonical indexed array with automatic schema,
validation, API, and digest coverage. Preserve path validation, mask mount
behavior, overlap precedence, symlink handling, and the limitation that runtime
masking does not remove content from a development-image build context.
Protected selected Containerfiles cannot be hidden. Core machine commands
have no config-file cases; the frontend layer owns/protects its config files.

Each entry must be non-empty, project-relative, existing regular file/directory,
unique and non-overlapping with another hidden ancestor, without dot segments,
colon, trailing slash, special type, or symlink component, and canonically
beneath the physical project. A host symlink prefix used to reach the canonical
project remains valid. Implement `check_hidden_path` over
`check_project_mount_path`; reject missing paths because masking does not
reserve names.

Build one quoted `--security-opt mask=PATH:PATH` array element from fully
validated container-absolute paths. Never synthesize bind sources, tmpfs,
FUSE, placeholders, or runtime-state directories; never evaluate/word-split
values. Make `rprivate` explicit on the project base and all project overlays.
If Podman rejects masking, fail creation and never retry unmasked.

The precedence contract is:

```text
hidden mask > protected read-only overlay > writable lane > project base
```

Exact hidden/read-only overlap and hidden paths beneath read-only/writable paths
are valid and hidden wins. A read-only/writable child beneath a hidden directory
is validated then omitted so it cannot re-expose content. Automatic selected
Containerfile may be hidden after host consumption and counts as stronger than
read-only; config-file cases belong only to the frontend layer.

Writable/read-only/hidden composition is deterministic and fails before
mutation on invalid or contradictory protected inputs. Changes make existing
resources incompatible and require explicit lifecycle recovery.

Masking is pathname-scoped. Other hardlinks/copies remain readable, the pathname
may be inferable, and host content must stay mounted/unchanged. It applies only
at runtime: Containerfiles can read/copy entries inside `DEV_BUILD_CONTEXT`
before masks exist. Users must exclude secrets with container ignore files or
keep them outside context; jailbox does not edit ignore files or repair images,
caches, Git history, logs, or copies.

Add the key to public declarations/defaults/schema/parser/API-diff and digest;
add lexical validation in `host/common.sh`, semantic/overlap and option state
in `host/container-runtime.sh`, pre-side-effect validation, launch-state
assertions, native option emission, and readiness checks. No new cleanup or
project-state behavior is introduced.

## Tests and documentation

Portable/runtime tests cover indexed members, comma-bearing paths, every
overlap/ancestor relationship, files/directories/missing paths, Containerfile
protection, digest mismatch, mount isolation, and build-context documentation.
No editor-gate requirement applies here; later editor-specific coverage gets
a new frontend plan when needed.

Also cover literal glob/option-like segments, quoted option construction,
explicit private propagation, option failure without retry, masked file and
directory read/write/list denial with read-only root, host visibility unchanged,
readable hardlink/copy aliases, child-mount non-reexposure, inspect policy, and
stale exec/shell refusal. Extend plan 7's real-Podman fixture and update its
empty-base expectation from `:Z` to `:Z,rprivate`; effective isolation, not
argument order/inspect alone, is the contract.

Run `tests/run portable` and `tests/run runtime`.

## Acceptance criteria

- Valid hidden paths are inaccessible at runtime with documented precedence.
- A selected Containerfile may be hidden only after host consumption and is
  treated as stronger than read-only; build context is not misrepresented.
- Invalid or changed policy fails before mutation under shared compatibility.
- Native masks win every overlap without propagating to or modifying the host.
- Missing/special/symlinked/outside/duplicate/ancestor-overlap entries fail.
- Documentation states pathname and pre-build limitations without claiming
  secrecy after copying.

## Non-goals

- Removing build-context content, core config-file protection, editor testing,
  or automatic lifecycle replacement.
- Reserving absent paths, hiding pathnames/types, replacement secret transport,
  or an unsupported-runtime fallback implementation.
