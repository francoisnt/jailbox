# Backlog

Potential future improvements that are deliberately outside current
implementation plans. These are ideas to reassess, not approved designs or
commitments.

## Lifecycle safety

### Explicit stop before relaunch

Replace implicit container replacement with a two-command lifecycle: refuse to
launch while either project container exists and direct the user to run
`jailbox stop`. A stop command could remove only the development and proxy
containers while preserving images, networks, the home volume, and SSH state.

This would prevent a running sandbox with a writable project mount from racing
host-side launch validation and image builds. It would also mean a failed
relaunch leaves no previous sandbox running.

### Lifecycle locking

Serialize launch, stop, and cleanup operations per project. Removing Podman's
`--replace` behavior prevents silent container replacement but does not protect
shared SSH, network, volume, or proxy state from concurrent lifecycle commands.

### Container-name collision handling

Before launch or stop, inspect existing development and proxy containers and
verify that their `jailbox.project` label matches the canonical project path.
Distinguish an owned leftover from an unrelated container using the same
derived name, and never remove an unowned collision automatically.

### Ownership-aware cleanup

Before `--clean` removes containers, volumes, or networks by derived name,
verify their `jailbox.project` labels. Skip and report unlabeled or mismatched
resources while continuing to remove resources jailbox can prove it owns.

## Trusted launch inputs

### Optional project policy anchor

Consider creating a default `jailbox.conf` and protecting it automatically so a
sandbox cannot author the policy consumed by the next launch. If pursued, its
creation must publish complete contents atomically without overwriting an
existing path, handle concurrent creators, reject symlinks and non-regular
files, and avoid affecting commands that do not launch a sandbox.

This would intentionally qualify the simpler rule that the read-only set is
entirely explicit, so it requires a separate security-model decision.

### Trusted-input validation

Validate host-consumed project inputs independently of read-only mount policy:

- the selected configuration file before parsing;
- the selected or discovered Containerfile before `podman build`; and
- `DEV_BUILD_CONTEXT` before exposing it to the build.

Project-reachable spellings with leaf or intermediate symlinks could be
rejected so a writable sandbox cannot redirect a later host invocation outside
the project. Directly selected external inputs would need an explicit policy.

### Automatic trusted-input protection

Consider automatically mounting an in-project selected config and exact
Containerfile read-only. This would protect inputs consumed on the next launch,
but it conflicts with a strictly explicit `READONLY_PATHS` model and should be
evaluated separately from trusted-input validation.

## Filesystem race hardening

### Close validation-to-mount races

The current design can recheck paths immediately before constructing Podman
mount arguments, but Podman resolves those paths later. Explore whether
descriptor-relative filesystem APIs, lifecycle locking, or another design can
bind validation to the object ultimately mounted. Document residual host-side
races if they cannot be eliminated.

### Atomic no-replace file publication

If jailbox later creates project policy files, use a complete temporary regular
file in the destination directory and publish it with atomic no-replace
semantics. Distinguish an actual concurrent winner from permission, filesystem,
or I/O failures, and remove temporary files on every path.

## Launch diagnostics

### Early port-conflict detection

When launch requires project containers to be absent, always probe the derived
SSH port before image work and report a clear conflict for unrelated listeners.
The current exception for an existing replaceable container could then be
removed.
