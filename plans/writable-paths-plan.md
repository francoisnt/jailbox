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

- Empty or omitted: mount the project read-write, then apply the automatic
  config/Containerfile overlays and configured `READONLY_PATHS` overlays.
- Non-empty: mount the project read-only, overlay each listed lane read-write,
  then apply protected read-only overlays last.

No Bash-array syntax is accepted in config files.

## Visible behavior

In allowlist mode:

- the whole project remains readable for builds and tests;
- writes succeed only within listed lanes;
- the selected config, selected Containerfile, and configured `READONLY_PATHS`
  remain read-only even when nested inside a writable lane; and
- denied writes fail at the mount layer.

The precedence invariant is:

```text
protected read-only overlay > writable lane > read-only project base
```

`WRITABLE_PATHS` does not hide secrets. Sensitive material that must not be read
should not be placed in the mounted checkout.

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
mount inputs, including `READONLY_PATHS`, so policy does not vary by feature.

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

Implement the project-label policy established by
`selinux-mount-labels-recommendation.md`. Complete its enforcing-host
verification before adding writable lanes, then verify this mount ordering on
the supported Podman/SELinux matrix.

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

Listing `.git/config` and `.git/hooks` in `READONLY_PATHS` prevents direct
changes to them, but does not make agent-authored Git objects or refs trusted.
The external orchestrator or human must inspect commits before integration.

Independent commit histories require independent clones. Multiple sandboxes
must not share one writable `.git` directory.

## Protected paths

Every `READONLY_PATHS` entry must exist and pass the validation defined in
`protected-path-policy-plan.md`. Writable lanes must not weaken or bypass any
effective protected overlay.

## Safe reuse

`WRITABLE_PATHS` participates in the config digest defined by
`headless-mode-plan.md`, automatically: that digest covers every key in
`CONFIG_SCALAR_KEYS` and `CONFIG_ARRAY_KEYS`, so adding this key to
`CONFIG_ARRAY_KEYS` is all that is required.

Changing the allowlist must prevent a running sandbox from being used until it
is relaunched. A liveness check alone is insufficient. Note the semantics
settled in the command-mode plan: `exec` and `shell` never replace a sandbox,
they *fail* on a digest mismatch and direct the user to `jailbox up`. There is
no `start` command, and no automatic replacement anywhere.

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
- Expand possibly empty mount arrays as `"${array[@]}"`. This is `host/` code,
  which targets Bash 4.4 or newer; the `${array[@]+"${array[@]}"}` form belongs
  only to `install.sh` and other explicitly Bash 3.2-constrained code.

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
- With `.git` writable and `.git/config` plus `.git/hooks` listed in
  `READONLY_PATHS`, a commit succeeds while those paths remain protected.
- Absolute, traversing, missing, file-valued, duplicate, nested, and symlinked
  lanes are rejected.
- A symlink to a host path outside the project can never become a writable
  mount.
- A writable lane equal to or beneath a protected path is rejected.
- An absent `READONLY_PATHS` entry fails clearly in every mount mode.
- Tightening the allowlist changes the config digest, so `exec` against the
  sandbox launched under the looser allowlist fails until `jailbox up` is run.

Run the portable gate and, because this changes host mounts and the security
contract, the runtime gate wherever Podman is available.

## Non-goals

- No profiles, inheritance, or per-config resource identities.
- No `HIDDEN_PATHS` or general read confinement.
- No orchestration, checkout management, scheduling, or merging.
