# `WRITABLE_PATHS` — deny-by-default project writes

## Goal

Add one allowlist mode that confines a sandbox to writing specified project
subtrees while leaving the rest of the project readable. This is a write
boundary, not a general filesystem secrecy mechanism.

The caller chooses the lanes in the selected config file. Concurrent agents use
separate checkouts and separate external configs; jailbox does not provide
profiles or multiple identities for one checkout.

## Configuration

`WRITABLE_PATHS` is a comma-separated config array, matching the existing
strict data grammar:

```conf
WRITABLE_PATHS=sections/checkout,.git
```

- Empty or omitted: current behavior. Mount the project read-write, then apply
  the built-in and configured read-only overlays.
- Non-empty: mount the project read-only, overlay each listed lane read-write,
  then apply protected read-only overlays last.

No Bash-array syntax is accepted in config files.

## Visible behavior

In allowlist mode:

- the whole project remains readable for builds and tests;
- writes succeed only within listed lanes;
- built-in protected paths and `READONLY_EXTRA` remain read-only even when they
  are nested inside a writable lane; and
- denied writes fail at the mount layer.

The precedence invariant is:

```text
protected read-only overlay > writable lane > read-only project base
```

`WRITABLE_PATHS` does not hide secrets. Sensitive material that must not be read
should not be placed in the mounted checkout. `HIDDEN_PATHS` is not part of this
proposal.

## Path safety

Path validation is part of the security boundary.

Each entry must:

- be a non-empty project-relative path;
- contain no `.` or `..` segment and no trailing slash;
- exist before launch;
- be a directory, not a file;
- contain no symlink component; and
- resolve canonically beneath canonical `$PROJECT_DIR` immediately before its
  mount is constructed.

Reject duplicate lanes and a lane nested under another writable lane as
redundant. Do not silently normalize unsafe input.

The same canonical containment helper should be used for other project-relative
mount inputs, including `READONLY_EXTRA`, so policy does not vary by feature.

## Interaction with protected paths

For writable lane `W` and protected read-only path `R`:

| Relationship | Decision |
|---|---|
| `R` is nested under `W` | Allowed; the later read-only overlay protects it. |
| `W == R` | Error; the declarations contradict each other. |
| `W` is nested under `R` | Error; it would punch a writable hole in a protected path. |

Mount project-tree paths parent-first:

1. read-only project base;
2. writable lanes, shallowest first;
3. protected read-only overlays, shallowest first where necessary.

The implementation must verify this behavior on the supported Podman/SELinux
matrix. The existing `:Z` versus `:z` project-label policy is a separate open
decision and must be settled before encoding either form as a new invariant.

## Git commits

The read-only base makes `.git` read-only. A caller that wants the sandbox to
create commits grants it explicitly:

```conf
WRITABLE_PATHS=sections/checkout,.git
```

The resulting layering is:

```text
read-only project
  -> read-write sections/checkout
  -> read-write .git
  -> read-only .git/config and .git/hooks
```

This prevents direct changes to the protected Git config and hook locations,
but does not make agent-authored Git objects or refs trusted. The external
orchestrator or human must inspect commits before integration.

Independent commit histories require independent clones. Multiple sandboxes
must not share one writable `.git` directory.

## Absent protected paths

The current launcher may create mountpoint stubs for absent protected paths on
a writable project base. This proposal does not redesign that lifecycle.

In allowlist mode, no stub is needed for an absent protected path outside every
writable lane because the read-only base already prevents its creation. An
absent protected path inside a writable lane still needs a safe mountpoint
strategy before that lane can be supported.

For the first implementation, fail clearly when such a protected path is absent
inside a writable lane. Do not introduce temporary directory markers, cleanup
indexes, recursive removal, or crash-recovery behavior as part of this feature.
That narrower failure is preferable to adding race-sensitive deletion logic to
the host tool.

## Safe reuse

`WRITABLE_PATHS` participates in the effective-config fingerprint. Changing the
allowlist must force replacement of a running sandbox before `start` or `exec`
can reuse it. A liveness check alone is insufficient.

## Implementation outline

### Public API and parser

- Add `WRITABLE_PATHS` to `CONFIG_ARRAY_KEYS` and defaults.
- Reset it to an empty array in `apply_config_defaults`.
- Add it to `set_config_array`.
- Perform lexical validation after parsing and filesystem/canonical validation
  after project initialization.

### Runtime mounts

- Build the project base mount separately from its overlays.
- Empty allowlist: base is read-write.
- Non-empty allowlist: base is read-only.
- Build one read-write bind per validated lane.
- Emit read-only protected overlays after writable overlays.
- Use Bash 3.2-safe expansion for possibly empty mount arrays.

### Validation

Extend post-start validation to prove both sides of the boundary:

- a write inside every configured lane succeeds;
- a write outside the lanes fails;
- protected files nested within a lane remain read-only; and
- no configured source path resolves outside the project.

Validation markers must be created and cleaned without overwriting user files.

## Tests

- Empty `WRITABLE_PATHS` is byte-for-byte compatible with current mount mode.
- A write inside a lane succeeds and a sibling write fails.
- A protected path inside a lane remains read-only.
- With `.git` writable, a commit succeeds while `.git/config` and `.git/hooks`
  remain protected.
- Absolute, traversing, missing, file-valued, duplicate, nested, and symlinked
  lanes are rejected.
- A symlink to a host path outside the project can never become a writable
  mount.
- A writable lane equal to or beneath a protected path is rejected.
- An absent protected path inside a writable lane fails clearly; outside the
  lanes it requires no stub and cannot be created.
- Tightening the allowlist changes the fingerprint and replaces a running
  sandbox.

Run the portable gate and, because this changes host mounts and the security
contract, the runtime gate wherever Podman is available.

## Non-goals

- No profiles, inheritance, or per-config resource identities.
- No `HIDDEN_PATHS` or general read confinement.
- No managed temporary-stub cleanup system.
- No orchestration, checkout management, scheduling, or merging.
