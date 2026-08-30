# Backlog

Potential future improvements that are deliberately outside current
implementation plans. These are ideas to reassess, not approved designs or
commitments.

## Lifecycle safety

### Lifecycle locking

Serialize launch, stop, and cleanup operations per project. Removing Podman's
`--replace` behavior prevents silent container replacement but does not protect
shared SSH, network, volume, or proxy state from concurrent lifecycle commands.

### Ownership-aware cleanup

Before `--clean` removes containers, volumes, or networks by derived name,
verify their `jailbox.project` labels. Skip and report unlabeled or mismatched
resources while continuing to remove resources jailbox can prove it owns.

## Trusted launch inputs

### Policy-aware project initialization

Consider extending `jailbox init` to seed `READONLY_PATHS` from existing
security-sensitive project paths, such as `.env`, Git policy files and hooks,
Gitea or GitHub workflow directories, and an in-project jailbox source
directory.

This needs a separate design because projects have different layouts and every
configured read-only path must exist. Decide whether initialization should:

- detect only existing paths from a documented candidate set;
- prompt interactively for each candidate or generate a deterministic
  non-interactive policy;
- provide explicit flags for automation and non-TTY use;
- show skipped absent paths without creating stubs;
- preserve stable output ordering; and
- distinguish paths protected automatically, such as the default config and
  exact used Containerfile, from additional paths written to `READONLY_PATHS`.

The current initialization plan deliberately creates the minimal
`READONLY_PATHS=` policy and performs no project inference.

### Trusted-input validation

Extend the trusted-input validation established for selected configs and
Containerfiles to `DEV_BUILD_CONTEXT` before exposing it to the build.

Project-reachable spellings with leaf or intermediate symlinks could be
rejected so a writable sandbox cannot redirect a later host invocation outside
the project. Directly selected external inputs would need an explicit policy.

## Filesystem race hardening

### Close validation-to-mount races

The current design can recheck paths immediately before constructing Podman
mount arguments, but Podman resolves those paths later. Explore whether
descriptor-relative filesystem APIs, lifecycle locking, or another design can
bind validation to the object ultimately mounted. Document residual host-side
races if they cannot be eliminated.
