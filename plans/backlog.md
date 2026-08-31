# Backlog

Potential future improvements that are deliberately outside current
implementation plans. These are ideas to reassess, not approved designs or
commitments.

## Lifecycle safety

### Lifecycle locking

Serialize launch, stop, and cleanup operations per project. Removing Podman's
`--replace` behavior prevents silent container replacement but does not protect
shared SSH, network, volume, or proxy state from concurrent lifecycle commands.

### Digest diagnostics in `doctor`

After the configuration-digest attachment gate lands, extend `doctor` to report
the digest recorded on an owned development container and, when the current
configuration can be selected and validated without changing doctor's
config-optional contract, whether it matches the reproducible current digest.
Define useful output for absent, stopped, foreign, unlabeled, stale, and
configuration-unavailable states without making `doctor` mutate resources or
require an editor. Do not expose the NUL-delimited serialization or imply that
the digest identifies which individual setting changed.

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

## Runtime isolation

### SELinux development-container policy

jailbox currently uses Podman's private `:Z` relabel option on the project and
other bind mounts. On an SELinux-enforcing host, this allows the confined
development container to access the checkout, but it persistently changes local
filesystem labels that Git does not track or restore. Repeated private labels on
nested project overlays may also be redundant.

Reassess the development-container policy independently of the numbered path
and command plans. Compare at least:

- retaining private `:Z` labeling, ideally once on each independent bind source
  with nested project mounts inheriting the project label;
- using `--security-opt label=disable` and no `z`/`Z` suffixes for development-
  container binds, accepting that rootless Podman, namespaces, mount selection,
  dropped capabilities, and `no-new-privileges` become the principal host
  boundary; and
- exposing an explicit strict configuration choice between those modes without
  any silent fallback from private labeling to disabled labeling.

Keep the proxy container's label policy separate: it does not mount the project
and has no equivalent repository-relabeling concern. Any selected design must
document whether checkout labels persist after `stop`, `--clean`, failure, or
uninstall; must not attempt to guess and restore prior labels; and must be tested
on a disposable Fedora VM where `getenforce` reports exactly `Enforcing`.
Non-enforcing CI can report a skip but cannot verify the SELinux contract.

The numbered plans preserve the existing `:Z` convention in the meantime and
do not depend on resolving this investigation.

### KVM-backed development runtime

Investigate an optional VM-backed OCI runtime that gives the development
workload a guest kernel while preserving jailbox's Podman-oriented lifecycle.
The closest current candidate is libkrun through Podman's
`--runtime=krun`, but availability and behavior must be verified rather than
assuming the flag is a drop-in isolation upgrade.

The investigation must cover:

- supported Linux distributions, architectures, hardware virtualization, KVM
  access, rootless operation, and installation burden;
- ordinary OCI development images and the jailbox wrapper build;
- project binds, nested read-only/writable overlays, named home storage,
  ownership, `--read-only`, and tmpfs behavior through the VM file-sharing
  layer;
- SSH port forwarding, Podman networks, the egress proxy sidecar, and lifecycle
  inspection/removal;
- resource limits and the meaning of existing capability, seccomp,
  `no-new-privileges`, and SELinux options under the alternate runtime;
- explicit failure when the requested runtime or KVM is unavailable, with no
  silent fallback to the ordinary host-kernel runtime; and
- whether a private VM filesystem plus controlled Git patch/commit export would
  provide a stronger and simpler boundary than sharing the live host checkout.

Do not make `krun`, Kata Containers, `crun-vm`, or another alternate runtime a
prerequisite for the numbered implementation sequence. If an experimental
runtime setting is later added, include it in the configuration digest and run
the complete portable, runtime, and editor gates for each supported mode.
