# Backlog

Potential future improvements that are deliberately outside current
implementation plans. These are ideas to reassess, not approved designs or
commitments.

> Note (September 2026): the repository split is deferred; the editor workflow
> is an in-repo frontend layer over the machine interface (plan 03.2.11) and
> the generic `WRAPPER_SETUP` mechanism is archived with the split. Entries
> elsewhere in this file are written against that frontend layer. Three
> entries are exceptions that describe the split-era two-product design and
> apply as written only if the split is revived — "Orchestrator-managed editor
> launch", "Richer wrapper setup inputs", and "Shared runtime source"; they
> keep the split-era names JailIDE and `WRAPPER_SETUP` deliberately. See the
> addendum in `repository-split-rationale.md`.

## Lifecycle safety

### Named project instances

Consider an explicit jailbox instance selector so one physical project can have
multiple independently managed sandboxes, with the editor frontend exposing
instances as named profiles. Derive resource identity from the physical
project identity and the validated instance name. Keep one project hash for
the physical checkout; deterministic names, not removable ownership labels,
establish identity.
Include a normalized instance-name component in every Podman container,
network, and volume name, as well as its SSH alias and runtime-state path. This
lets multiple configurations share the same project hash while Podman's name
uniqueness keeps their resources separate. Keep the effective configuration and
Containerfile identity in the separate compatibility digest rather than hashing
configuration into resource names. Preserve the current single-instance
behavior by default.

A later design must cover the selector for every lifecycle and connection
command, instance-aware deterministic resource and runtime-state names, SSH
aliases, `connection-info`, status and cleanup behavior, validation and
normalization of instance names, concurrent access to the same project
checkout, and migration from existing unqualified resources. Use a neutral core
concept such as an instance; the human-facing profile name remains owned by
the frontend.

### Lifecycle locking

Serialize lifecycle operations per project. Validation before mutation is a
check-then-act sequence, and the frontend runs `up` then `connection-info` as
two processes, so concurrent work can invalidate either decision.
Until locking lands, callers must coordinate per project and exclude lifecycle
mutation from dependent sequences such as `up` then `connection-info`. This
is a caller obligation, not an existing CLI lock; independent terminals can
still race. The future design must address the multi-command interval as well
as individual lifecycle commands.

### Digest diagnostics in `doctor`

Doctor already diagnoses missing and inconsistent version-bound digest labels
on the development container, proxy container, and network. Narrow this future
work to comparing those labels with an explicitly supplied current policy;
ordinary doctor remains configuration-independent.

After the configuration-digest attachment gate lands, extend `doctor` to report
the digests recorded on the derived project resource set and, when the current
configuration can be selected and validated without changing doctor's
config-optional contract, whether they all match the reproducible current
digest. Define useful output for absent, stopped, partial, unlabeled, stale, and
configuration-unavailable states without making `doctor` mutate resources or
require an editor. Do not expose the NUL-delimited serialization or imply that
the aggregate digest alone identifies which individual setting changed. If the
per-input diagnostics below land, they replace this aggregate-only diagnosis
rather than being added alongside it.

### Per-input digest mismatch diagnostics

After aggregate configuration-digest enforcement lands, consider advisory
per-input hashes that can name covered configuration inputs which differ without
printing their values. The aggregate digest must remain the only attachment
security decision, and older or incomplete diagnostic metadata must fall back
to the ordinary aggregate mismatch message.

Publishing an input hash must be explicitly opted into after reviewing whether
the value may be secret or easily guessed; future configuration keys must not be
enrolled automatically. Any resulting diagnostic replaces 03.2.09.1's current
aggregate-only mismatch explanation and the `doctor` diagnostic above rather
than adding another overlapping message. A later design should settle coverage,
compatibility, metadata exposure, and honest reporting for inputs it cannot
compare.

## Trusted launch inputs

### New-home bootstrap

Consider a trusted setup artifact that an orchestrator or the editor frontend
can request through jailbox only when jailbox
creates a new empty sandbox home. This would make the opt-in
`EPHEMERAL_HOME=true` mode convenient by reinstalling shell configuration,
development tools, and other reproducible user state without preserving files
written by an earlier sandbox generation.

A later design must define artifact selection and trusted-path validation,
read-only protection for an in-project artifact, content identity, execution as
the managed user after SSH readiness, access only through the sandbox's
effective egress policy, retry and partial-failure behavior, idempotence
expectations, and an out-of-project completion record. It must not inject
credentials implicitly or run on a reused non-empty home. Executing an
explicitly selected trusted artifact is caller-authorized code execution, not
evaluation of configuration as shell syntax.

### Policy-aware project initialization

Consider extending `jailbox init` to seed `READONLY_PATHS` from existing
security-sensitive project paths, such as `.env`, Git policy files and hooks,
Gitea or GitHub workflow directories, and an in-project jailbox source
directory.

A minimal advisory variant — detected candidates written only as
commented-out suggestions, with nothing enabled — is now part of plan
03.2.11's `init` scope. This entry covers the remaining interactive and
flag-driven design that actually enables policy.

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

Under the caller contract, extend core's Containerfile validation to
`DEV_BUILD_CONTEXT`, and require callers to validate and protect policy inputs
such as a selected `jailbox.conf`.

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

### Orchestrator-managed editor launch

Support a host orchestrator that owns a jailbox lifecycle but wants JailIDE to
launch a host editor against the resulting sandbox. The orchestrator must be
able to obtain every editor-specific launch contribution before `jailbox up`,
then ask JailIDE to attach without transferring lifecycle ownership.

A later design should define a two-phase public contract:

1. a non-mutating JailIDE requirements command consumes canonical JailIDE
   configuration and emits strict machine-readable jailbox inputs; and
2. after the orchestrator creates the matching sandbox, a non-mutating JailIDE
   attach command validates it and launches the selected host editor.

The requirements phase must cover more than egress. It needs a settled
environment-variable configuration interface for JailIDE automation, selected
editor and server-version identity, bootstrap/download hosts, container runtime
packages and dependencies, bootstrap destinations, required mounts/environment,
protected source paths, and every contribution to jailbox wrapper-cache and
configuration-digest identity. Output must be declarative data rather than
shell fragments or commands for the orchestrator to evaluate.

Container preparation uses the numbered plans' ordered `WRAPPER_SETUP`
interface. JailIDE owns the editor-specific setup contribution; jailbox
validates and incorporates it without editor knowledge; the orchestrator owns
final policy composition and calls `jailbox up`. The design must define merge
and conflict rules so neither JailIDE nor the orchestrator can silently
override core security policy or one another's declared inputs.

The attach phase receives the same effective jailbox environment used for
creation and the same JailIDE configuration identity. It resolves one compatible
installed jailbox executable, requires an already-running healthy digest match,
uses documented machine interfaces, generates the JailIDE-owned profile and
settings, and launches the host editor. It never calls `up`, `stop`, or `clean`,
invokes Podman directly, changes container policy, or obtains a container-engine
socket. Host-only SSH credentials remain host-only.

Bind requirements and attach with a reproducible JailIDE contribution digest or
equivalent receipt so changed editor, configuration, egress, dependency, or
setup inputs cannot attach as though they created the running sandbox. Define
behavior for absent/stopped resources, stale requirements, incompatible jailbox
versions, missing editor prerequisites, direct non-orchestrated JailIDE launch,
and filtered-egress failures. Portable tests should use a fake jailbox client;
the editor gate should cover both direct launch and orchestrator-managed
requirements/up/attach using immutable artifacts.

### Richer wrapper setup inputs

The numbered plans provide ordered, content-addressed caller setup scripts and
use one for JailIDE's editor dependencies. Reassess a richer extension bundle
only after a real consumer needs auxiliary files or metadata that cannot
reasonably be embedded or created by its script.

A later design must preserve the existing root-code trust boundary, validation
before mutation, deterministic ordering, isolated build context, build-network
contract, read-only protection, wrapper-cache/configuration-digest identity,
and final jailbox hardening. It must define an allowlisted file inventory,
destination conflicts, symlink/special-file refusal, bundle compatibility, and
whether multiple scripts can share assets. Configuration remains strict data:
running a separately selected trusted artifact is intentional caller-authorized
code execution, not evaluation of a configuration value as shell syntax.

### Shared runtime source

No shared runtime source is planned, and the products no longer share a
language: jailbox is Bash and JailIDE is Go, so a common source library is
off the table by construction. Shared behavior lives only in jailbox's
documented machine interfaces (environment configuration, `config-schema`,
`status`, `connection-info`), which any language can consume. Reassess only
if a future same-language sibling product needs an identical,
caller-independent contract that can be tested completely through
independent fixtures.

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
uninstall; must not attempt to guess and restore prior labels; and must be
tested on a disposable Fedora VM where `getenforce` reports exactly `Enforcing`.
Non-enforcing CI can report a skip but cannot verify the SELinux contract.

The numbered plans preserve the existing `:Z` convention in the meantime and
do not depend on resolving this investigation.

### Optional managed VM enclosure for Podman-dependent tests

Consider optionally running jailbox's existing development container and egress
proxy inside a standard managed Linux VM. Keep direct container execution as
the default. The VM adds a guest-kernel boundary while retaining the existing
container image workflow and hardening. Use an existing VM manager and run
container orchestration inside the guest, where Podman storage paths and mounts
remain local to the machine executing them.

The immediate need is autonomous execution of tests requiring Podman: the
runtime and editor gates. Portable tests, linting, builds, and ordinary
development that do not require a container engine continue in the existing
sandbox without requiring a VM. A VM is an optional isolation and test-host
facility, not a new prerequisite for every command or another test gate.

Explore direct access from the development container to the dedicated guest's
Podman engine as the simpler way to enable those tests. Treat that access as
guest-account code-execution authority: it can bypass container-level mount
and network restrictions and affect other resources owned by that guest
account. The host's engine and personal credentials must remain inaccessible.
This would be an explicit opt-in exception to the no-engine-access policy for
this VM mode only; direct host-container execution retains that policy.
Enforce host protection through the VM boundary and tightly scoped file shares,
and enforce any promised egress restrictions outside agent-controlled guest
resources. A writable host share remains writable with guest engine access;
container read-only overlays alone cannot protect paths within that share.

Account for guest-side bind paths and commands that require local Podman
storage access; an engine connection alone may not make every existing test
work from inside the development container. Provide guest-side execution where
needed, along with the editor gate's editors and virtual display, and return
logs and exit status without manual host commands.

A later design should cover VM provisioning and updates, project sharing or
snapshot transfer (including uncommitted changes), protected-path enforcement,
guest ownership and persistent storage, SSH forwarding and host editor access,
resource limits, and effective egress policy for both development and tests.
Define VM ownership and lifetime, stop/clean semantics, interrupted-operation
recovery, machine-interface reporting, configuration identity, and explicit
failure when the requested VM support is unavailable. Preserve project-scoped
state and validate the existing three gates for both supported execution modes,
while keeping routine portable test execution independent of the VM.

This enclosure is distinct from the VM-backed OCI runtime investigation below:
it places the container engine and a test execution environment inside the VM,
providing a place to run container tests without granting the sandbox host
authority. It remains outside the current numbered implementation sequence.

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
jailbox's complete portable, runtime, and editor gates for each supported
mode.

## Developer experience

### Test-log pruning

`testlog/` accumulates one directory per recorded run without bound. Consider
age- or count-based pruning in the run-metadata helper that keeps recent runs
and never touches anything outside `testlog/`.

### Shell completion

Consider a Bash completion script for the command and flag set, installed and
removed by `install.sh`. Reassess after the 03.2 command surface lands, and
generate the completion list from `host/public-api.sh` rather than
duplicating it.

### README terminal recording

The README carries a TODO for a launch recording. Consider a checked-in vhs
tape script that reproduces the recording deterministically, so the GIF can
be regenerated in one command as the CLI evolves.
