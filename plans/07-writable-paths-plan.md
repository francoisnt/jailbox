# 7. Writable project paths

## Goal

Allow explicit, narrowly validated writable subpaths while preserving automatic
read-only protection of core and caller policy inputs.

## Sequence

Requires `01-protected-path-policy-plan.md`,
`03.1-environment-only-configuration-plan.md`,
`03.2.02-configuration-digest-plan.md`, and
`03.2.06-constrained-up-plan.md`.

## Policy

Declare `WRITABLE_PATHS` as a canonical indexed array through the automatic
schema, validation, public-API, and digest mechanisms. Preserve
`check_project_mount_path`, canonical containment, overlap resolution,
symlink/nonexistent-path rules, mount ordering, and default project read-only
behavior. A writable request cannot override a protected path.

Empty/unset preserves the current byte-for-byte read-write project-base mount
and later read-only overlays. Non-empty mounts the project base read-only,
overlays each writable lane read-write, then applies protected overlays last:

```text
protected read-only overlay > writable lane > read-only project base
```

Each lane must be non-empty, project-relative, existing regular file/directory,
without dot segments, colon, trailing slash, duplicates, nested duplicate
lanes, special files, or any symlink component, and must canonically remain
beneath the physical project immediately before mount construction. Implement
`check_writable_path` over archived plan 1's
`check_project_mount_path`, not a parallel containment algorithm.

For writable `W` and protected `R`: allow `R` beneath `W` and apply the
read-only overlay last; reject equality; reject `W` beneath `R`. Mount the
base first, writable lanes shallowest first, then protected overlays. Preserve
the current private `Z` convention at this stage.

An existing regular-file lane supports in-place writes but not sibling-temp
plus rename because its parent stays read-only. Applications needing create,
delete, or atomic replacement must list the parent directory.

Core machine commands automatically protect their selected Containerfile but
no longer know or protect config files. The frontend layer deterministically
adds its default and selected in-project configuration files to final
read-only paths. Both the `KEY=value` file grammar and the environment model
reject control characters, so control-character-bearing paths are not
representable;
confirm that limitation remains acceptable before shipping.

A policy change makes resources incompatible. Recovery is explicit stop/up
under 03.2.04/06, not replacement by up.

Allowing `.git` is explicit. Read-only `.git/config` and `.git/hooks`
overlays can remain protected while commits write objects/refs, but this does
not make agent-authored commits trusted and multiple sandboxes must not share
one writable Git directory.

Add `WRITABLE_PATHS` to `CONFIG_ARRAY_KEYS`/defaults, schema, parser
assignment, API diff fixtures, digest coverage, mount state in
`host/container-runtime.sh`, semantic validation, readiness validation, and
README. Use normal Bash 4.4 empty-array expansion in host code.

## Security, tests, and documentation

Retain read-only roots, dropped capabilities, no-new-privileges, socket
isolation, containment, and protected-input precedence. Portable/runtime tests
cover indexed values including commas, overlap combinations, protected
Containerfile, the frontend composition boundary, digest changes, and refusal.
Cover many-member configurations with combined overlays that include writable
lanes; jailbox imposes no application-defined member maximum, and no dedicated
large-mount runtime fixture is required.

Production readiness proves directory-lane marker create/remove with
collision-resistant no-clobber cleanup; never modifies an arbitrary user file.
For regular-file-only policies, inspect effective mounts and skip an
inapplicable destructive outside write probe rather than creating a host path.
Controlled fixtures prove in-place writes, failed sibling rename, allowed lane
writes, denied sibling writes, no UID-mismatch false warning, protected nested
paths, and Git commit behavior.

Run `tests/run portable` and `tests/run runtime`. The runtime gate must prove
the nested read-write lane inside a read-only base and nested read-only overlay
with real Podman; argument order alone is not evidence.

## Acceptance criteria

- Only validated declared subpaths become writable and protected paths always
  win.
- Core and the frontend each protect only inputs they know.
- Policy changes refuse compatible attach/up until explicit recovery.
- Empty policy preserves prior mount spelling/validation; non-empty policy
  permits only declared lanes.
- Absolute, traversing, colon, missing, special, duplicate, nested, symlinked,
  and outside lanes fail before mutation.
- A regular-file lane never makes its parent writable.

## Non-goals

- File config syntax in core, automatic replacement, or weakening protected
  path policy.
- Profiles, general read confinement, orchestration, scheduling, or merging.
