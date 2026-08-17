# Stub directories for absent protected paths

## Goal

Replace the current practice of materializing empty *file* stubs for absent
protected paths with self-documenting, read-only **stub directories** that are
invisible to Git and removed when the sandbox stops. This keeps a protected path
that does not yet exist from being created inside the container, without leaving
opaque empty files in the user's working tree.

Scope is the default mount mode (writable project base). Allowlist mode
(`WRITABLE_PATHS`) governs absent protected paths through its own spec; see
`writable-paths-plan.md`.

## Why a stub is needed

A read-only overlay needs a mountpoint, and the mountpoint for
`$REMOTE_PATH/<path>` is an inode in the bind-mounted host tree. A protected path
that is absent has no inode to overlay, so on a writable project base the
container could create it — a planted `.env` or CI workflow is exactly the write
the overlays exist to prevent. The launcher therefore materializes the path on
the host so it has something to mount read-only.

## Design

When a protected path is absent on a writable base, materialize it as a
**directory**, never a bare file, and mount that directory read-only —
regardless of whether the protected path is normally a file or a directory.

- A directory name blocks creation of a same-named file: `open(..., O_CREAT)` on
  a directory returns `EISDIR`.
- The read-only bind mount provides immutability: a bind-mount point cannot be
  unlinked while mounted (`EBUSY`) and its contents are read-only, so the
  container can neither replace the directory nor populate it.

This replaces the current behavior, which creates an empty file for file-valued
paths (`.env`) and an empty directory for directory-valued paths
(`.github/workflows`). Every stub is now a directory; the launcher never creates
a stub file.

### Contents

Each stub directory contains exactly two files, so it explains, hides, and
identifies itself with no change to the repository's root `.gitignore` or
`.git/info/exclude`:

- `.gitignore` containing `*` — ignores everything inside, including itself and
  the marker, so the stub never appears in `git status` and is never staged by
  `git add -A`.
- `JAILBOX-STUB` — a short note that jailbox created the directory to prevent a
  file from being created at this path. It also serves as the detection marker
  (see Removal).

## Removal

A stub exists only while the sandbox runs.

- Removed by `stop` and `--clean`, after the container — and therefore the
  read-only mount — is gone, so the directory is no longer a busy mountpoint.
- Pruned on the next launch / `start`, covering ungraceful stops (crash, reboot,
  a direct `podman stop`) that cannot trigger cleanup.

Removal is **marker-gated and non-recursive**, which is what keeps it from
becoming risky deletion logic. A directory is removed only when:

1. it carries the `JAILBOX-STUB` marker;
2. it contains nothing beyond its own two stub files;
3. its canonical path remains beneath canonical `$PROJECT_DIR`, with no
   symlink component; and
4. neither the candidate path nor anything beneath it is tracked in the
   project's Git index, including staged additions.

The launcher then deletes exactly `.gitignore` and `JAILBOX-STUB` and `rmdir`s
the now-empty directory. It never uses recursive removal, never removes a
directory lacking the marker, and never removes one that holds any other entry —
so a directory the user has since repurposed is left intact. A
`$SSH_DIR/created-stubs` index lists candidate paths, but the on-disk marker,
emptiness, containment, and Git-index checks — not the index — authorize
deletion, so a stale or lost index can never cause loss of real files. Repeat
all four checks immediately before deleting the two files and calling `rmdir`.
If containment or Git-index status cannot be determined reliably, fail closed
and leave the directory in place.

## Path safety

Stub creation and removal are host writes and part of the security boundary.
For each candidate path:

- resolve it canonically and require it to remain beneath canonical
  `$PROJECT_DIR`;
- refuse any symlink component;
- act only when the final path is genuinely absent; never replace, follow, or
  descend into an existing file, directory, or link.

## Implementation outline

- Rework `ensure_readonly_stubs` to create directory stubs with the two marker
  files, mount them read-only, and record them in `$SSH_DIR/created-stubs`.
  `Containerfile` and `Dockerfile` candidates are still never stubbed — a
  directory in their place would break dev-image discovery.
- Add stub teardown to the `stop` and `--clean` paths and a prune step to launch,
  using the marker-gated, non-recursive removal above.
- Use Bash 3.2-safe constructs and quote every path.

## Tests

- Default mode with `.env` absent: a stub *directory* `.env/` is created carrying
  `.gitignore` and `JAILBOX-STUB`, mounted read-only; the container cannot create
  a file at `.env`; `git status` is unchanged.
- `stop` and `--clean` remove the stub; a leftover stub is pruned on the next
  launch.
- Removal refuses a directory without the marker; a stub directory that has
  gained an extra file is left intact.
- Removal refuses a path outside the project, a path reached through a symlink,
  and a candidate with any tracked or staged Git entry at or beneath it. A Git
  query failure also leaves the candidate intact.
- A protected path that is a symlink, or resolves outside the project, is never
  stubbed.
- `Containerfile` / `Dockerfile` are never stubbed.

## Non-goals

- No stub *files*; every stub is a directory.
- No stubbing in allowlist mode outside a writable lane — the read-only base
  already prevents creation; the in-lane case is governed by
  `writable-paths-plan.md`.
- No recursive deletion and no removal of anything lacking the marker.
