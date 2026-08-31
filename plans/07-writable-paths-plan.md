# 7. `WRITABLE_PATHS` — deny-by-default project writes

## Goal

Add one allowlist mode that confines a sandbox to writing specified project
subtrees while leaving the rest of the project readable. This is a write
boundary, not a general filesystem secrecy mechanism.

The caller chooses the lanes in the selected config file. Concurrent agents use
separate checkouts and separate external configs; jailbox does not provide
profiles or multiple identities for one checkout.

## Sequence

Order 7.0. Requires `01-protected-path-policy-plan.md` for the shared
`check_project_mount_path` primitive and `04-config-digest-plan.md` for automatic
digest coverage of the new key. Its safe-reuse requirement — that changing the
allowlist prevents a stale sandbox from being used — is only enforceable once
`05-exec-command-plan.md` and `06-shell-command-plan.md` gate attachment on the
digest, so it lands after the full command-mode sequence.
`08-hidden-paths-plan.md` follows and extends this plan's mount precedence.

## Configuration

`WRITABLE_PATHS` is a comma-separated config array, matching the existing
strict data grammar:

```conf
WRITABLE_PATHS=sections/checkout,.git,build-status.json
```

- Empty or omitted: mount the project read-write, then apply the effective
  read-only overlays.
- Non-empty: mount the project read-only, overlay each listed lane read-write,
  then apply protected read-only overlays last.

No Bash-array syntax is accepted in config files.

## Visible behavior

In allowlist mode:

- the whole project remains readable for builds and tests;
- writes succeed only within listed lanes;
- every effective read-only entry — configured paths plus the automatic default
  config, selected config, and used Containerfile — remains read-only even when
  nested inside a writable lane; and
- denied writes fail at the mount layer.

The precedence invariant is:

```text
protected read-only overlay > writable lane > read-only project base
```

`WRITABLE_PATHS` does not hide secrets. Sensitive material that must not be read
should not be placed in the mounted checkout.

An existing regular file may be listed for programs that modify it in place.
Its parent directory remains read-only, so replacement patterns that create a
sibling temporary file and rename it over the configured file can fail. List
the parent directory instead when an application requires creation, deletion,
or atomic replacement.

## Path safety

Path validation is part of the security boundary.

Each entry must:

- be a non-empty project-relative path;
- contain no `.` or `..` segment, colon, or trailing slash;
- exist before launch;
- be a regular file or directory;
- contain no symlink component; and
- resolve canonically beneath canonical `$PROJECT_DIR` immediately before its
  mount is constructed.

Reject duplicate lanes and a lane nested under another writable lane as
redundant. Reject devices, FIFOs, sockets, and other special files. Do not
silently normalize unsafe input.

Use the shared project-relative mount-path validation established by plan 1.0,
including its colon rejection, and the same canonical containment helper for
`READONLY_PATHS` so policy does not vary by feature. Implement
`check_writable_path` as a policy-specific wrapper around
`check_project_mount_path`; add only the writable policy's duplicate, nesting,
and protected-path overlap decisions on top of the shared result.

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

Preserve jailbox's existing Podman relabel convention in this plan: the project
base uses private `Z` (`Z,ro` in allowlist mode), writable lane binds use
`Z,rw`, and protected overlays use `Z,ro`. Verify mount ordering and effective
read/write behavior in the ordinary runtime gate. A broader decision about
private relabeling, disabling development-container labels, persistent checkout
metadata, or enforcing-host-specific coverage is independent future work in
`backlog.md`; it does not block this path-policy feature.

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
`01-protected-path-policy-plan.md`. That plan also adds the existing default
config, selected in-project config, and used in-project Containerfile to the
effective set. Writable lanes must not weaken or bypass any effective protected
overlay.

## Safe reuse

`WRITABLE_PATHS` participates in the config digest defined by
`04-config-digest-plan.md`, automatically: that digest covers every key in
`CONFIG_SCALAR_KEYS` and `CONFIG_ARRAY_KEYS`, so adding this key to
`CONFIG_ARRAY_KEYS` is all that is required.

Changing the allowlist must prevent a running sandbox from being used until it
is relaunched. A liveness check alone is insufficient. Note the semantics
settled in `05-exec-command-plan.md`: `exec` and `shell` never replace a sandbox,
they *fail* on a digest mismatch and direct the user to `jailbox up`. There is
no `start` command, and no automatic replacement anywhere.

## Implementation outline

### Public API and parser

- Add `WRITABLE_PATHS` to `CONFIG_ARRAY_KEYS` and defaults.
- Reset it to an empty array in `apply_config_defaults`.
- Add it to `set_config_array`.
- Update `tests/unit/public-api-diff.sh` expectations for the new public
  configuration key.
- Perform lexical validation after parsing and filesystem/canonical validation
  after project initialization.

Review `scripts/public-api-diff.sh`: adding `WRITABLE_PATHS` is a minor
public-API change before 1.0.

### Runtime mounts

- Build the project base mount separately from its overlays.
- Empty allowlist: preserve the current base argument byte-for-byte as
  `-v "$PROJECT_DIR:$REMOTE_PATH:Z"`; do not add an explicit `rw` suffix.
- Non-empty allowlist: base is read-only.
- Build one read-write bind per validated regular file or directory.
- Emit read-only protected overlays after writable overlays.
- Expand possibly empty mount arrays as `"${array[@]}"`. This is `host/` code,
  which targets Bash 4.4 or newer; the `${array[@]+"${array[@]}"}` form belongs
  only to `install.sh` and other explicitly Bash 3.2-constrained code.

### Validation

Extend post-start validation to prove both sides of the boundary:

- for each configured directory lane, creation and removal of a uniquely named
  marker inside that directory succeeds;
- for a configured regular-file lane, inspect the container's effective mount
  table and mount flags but do not modify the user file;
- when `WRITABLE_PATHS` is empty, retain the existing check that the project
  root is writable;
- in allowlist mode, replace `check_project_write_access`'s unconditional
  writable-root assertion with a mode-aware base check: a controlled write
  outside every lane must fail, and an intentionally read-only project root
  must not produce the current UID-mismatch warning;
- protected files nested within a lane remain read-only; and
- no configured source path resolves outside the project.

Directory validation markers must use collision-resistant names, be created
with no-clobber semantics, and be removed on success and failure without
overwriting user files. Prove actual in-place regular-file writes and the failed
sibling-temp-and-rename behavior only in controlled unit/runtime fixtures whose
contents the test owns. Production validation must never alter and restore an
arbitrary user file: restoration races with concurrent writers and cannot be
made lossless.

Choose the denied-write probe destination from a validated existing directory
that is outside every writable lane and effective protected overlay. It must
not depend on the project root itself accepting new entries, because a
writable lane may cover one child while the base remains read-only. If the
current project contains no safe existing directory for the production probe —
including a configuration made entirely of regular-file lanes — validate the
read-only base and individual mount flags from the container's effective mount
table and report that the destructive write probe was not applicable; do not
create a host path merely to test denial. Controlled runtime fixtures must
include an outside directory and prove an actual denied creation there.

## Tests

- Empty `WRITABLE_PATHS` is byte-for-byte compatible with current mount mode.
- Empty `WRITABLE_PATHS` retains the existing writable-project validation. A
  non-empty allowlist expects the project base to be read-only and produces no
  false UID-mismatch warning from `check_project_write_access`.
- A write inside a lane succeeds and a sibling write fails.
- Allowlist configurations containing only regular-file lanes still validate
  mount flags without creating a host-side probe path; controlled fixtures
  separately prove an actual denied write outside those lanes.
- An existing regular file accepts in-place writes without making its parent
  directory writable; document and test the failed sibling-temp-and-rename case.
- A protected path inside a lane remains read-only.
- With `.git` writable and `.git/config` plus `.git/hooks` listed in
  `READONLY_PATHS`, a commit succeeds while those paths remain protected.
- Absolute, traversing, colon-containing, missing, special-file, duplicate,
  nested, and symlinked lanes are rejected.
- A symlink to a host path outside the project can never become a writable
  mount.
- A writable lane equal to or beneath a protected path is rejected.
- An absent `READONLY_PATHS` entry fails clearly in every mount mode.
- Tightening the allowlist changes the config digest, so `exec` against the
  sandbox launched under the looser allowlist fails until `jailbox up` is run.

Run the portable gate and, because this changes host mounts and the security
contract, the runtime gate wherever Podman is available.

Before relying on the layering implementation, cover the smallest real-Podman
fixture that mounts a nested read-write lane inside a read-only project base and
then applies a nested read-only overlay. Plan 8 extends the same fixture with a
mask over a bound path. These assertions are the executable compatibility
contract for Podman/OCI precedence; argument order alone is not evidence that
the security boundary holds.

## Non-goals

- No profiles, inheritance, or per-config resource identities.
- No `HIDDEN_PATHS` or general read confinement.
- No orchestration, checkout management, scheduling, or merging.
