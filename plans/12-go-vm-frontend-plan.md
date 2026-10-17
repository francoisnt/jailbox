# 12. VM execution for the Go frontend (deferred)

## Intent

Status: deferred. Preserve this specification for later work; it is not part
of current implementation or release acceptance. Resume only after a practical
strategy for real VM verification is available. Do not treat hosted CI skips
as evidence that a platform works.

Extend the Go frontend from `11.1-go-frontend-plan.md` with VM execution
selected by configuration under the same `jailbox` command. That plan owns
the Go migration, standalone Bash `jailcore`, source builds, and local tests
and packaging. This specification owns integrating that boundary with a
project-specific Linux VM;
the Go migration can ship independently.

VM mode opens the host editor into a jailbox development container while
keeping the host worktree live: authorized edits reach the original files in
both directions. The container can use the VM's Podman engine to create
sibling containers, so developers can run jailbox's own tests without granting
access to their device's engine or kernel. Local mode retains its existing
container security contract and needs no VM dependencies.

Keep both modes and core in the same repository and coordinated release.
This specification owns VM provisioning, host protection, guest-engine access,
VM editor integration, installation, and verification. The host-protection and
guest requirements below apply to VM mode.

### User experience and ownership

- Use the existing strict `jailbox.conf` format and editor selection. Support
  initialization, normal editor launch, headless launch, validation, status,
  shell/exec, stop, and clean through the same frontend in both modes.
  Add frontend-only `RUNTIME=local|vm`; absent means local for existing
  configurations, while `init` writes `RUNTIME=vm` explicitly for new projects.
  Unsupported values or unavailable VM support fail without local fallback.
- Support Linux, macOS, and Windows through native executables built from the
  same Go source. Local execution requires Linux and host Podman; VM execution
  uses hardware-accelerated QEMU with matching guest CPU architecture and needs
  no host Podman. Select machine/device combinations covered by QEMU's
  virtualization security policy. Users need no Go toolchain. Required OS
  virtualization setup must be diagnosed, not performed through silent
  elevation.
- Fetch a verified, versioned QEMU runtime and required helpers automatically
  on first VM use, cached per supported host OS/CPU combination. Include the
  required native libraries and firmware in that managed runtime. Keep it
  separate from the frontend executable and update it independently within
  declared compatibility bounds; local-only use must not download it. Own its
  platform builds, signing, redistribution requirements, and security updates.
- The host frontend owns the VM, host file exports, outer proxy, transport,
  and editor process. Core owns containers, networks, home state, and their
  readiness in both modes. Invoke it only through its versioned public CLI;
  do not inspect private core files or reproduce its lifecycle logic in Go.
- Extend the canonical declarations in `src/public-api.sh` through the Go
  generation and conformance checks owned by `11.1-go-frontend-plan.md`.
  Host VM settings belong to the frontend; changed container behavior requires
  declared core configuration and compatibility-digest coverage. Enforce the
  frontend's supported core version range inside the guest as well.
- The host editor connects through authenticated SSH to the development
  container, with the same editor profile isolation and bootstrap behavior as
  the existing frontend. Guest-local connection paths must be translated into
  validated endpoint/key data and host-owned SSH configuration. Never execute
  or include arbitrary SSH configuration returned by a guest. Keep fresh
  credentials, pinned host keys, and no agent or X11 forwarding. Bind connection
  targets to frontend-owned transports; translate proxy endpoints for the host
  editor rather than copying guest-private addresses into host settings.

Invoke the standalone `jailcore` inside the guest without requiring the Go
frontend there. Preserve its machine contract and explicitly select the
compatible guest installation. Source-based VM tests must provision matching
current-tree core/assets, not a stale guest copy with the same `dev` token.

### Host protection and live files

Treat the whole guest, its engine, and its persistent state as untrusted. The
host-approved policy is authoritative; guest configuration or a successful
guest readiness report cannot widen it. Use one VM and engine per project,
with host state outside the project and separate from local-mode state.
Keep QEMU management interfaces, host credentials, and physical-host
engine sockets inaccessible to guests.

Host state, SSH aliases, and editor profiles remain unique per canonical host
project and mode even when different VMs use identical guest paths or core
project IDs. Guest metadata cannot select another project's host state.

Enforce the complete permitted filesystem view outside the guest. Preserve
existing read-only/writable precedence, hidden masks, path validation, and
automatic protection of the default configuration, selected in-project
configuration, and selected in-project Containerfile. Guest root must not
uncover hidden content or writable protected originals by removing overlays,
remounting exports, or creating another container. Do not expose an unfiltered
parent export underneath restricted children. Preserve the documented
hard-link/copy limitations; do not claim to eliminate unrelated host-side
filesystem races.

Apply host path identity before exporting, including case-insensitive aliases
and Windows junctions/reparse points. An alternate spelling must not bypass a
protected path; reject unsupported filesystem semantics before booting the VM.

Host and guest edits must remain visible without import/export or a separate
synchronization workflow. Verify normal editor saves, authorized creation and
rename, permissions, and file-change notification behavior. Retain the current
regular-file writable-lane limitations. Report filesystem/platform restrictions
explicitly rather than silently weakening policy. Host paths may differ from
guest paths, but the engine and development session must resolve bind sources
to the same objects at the same guest paths, including temporary fixtures and
SSH/runtime state. Store Podman images and volumes on a native Linux guest disk.

VM builds use the permitted file view too: hidden host content is excluded
before any build input enters the guest. Reject a hidden required Containerfile
with an actionable diagnostic; consume a hidden frontend configuration on the
host without exporting its contents. Explicit external build inputs grant
only their selected, validated scope, with overlapping project restrictions
still applied. Document this VM-specific difference from local mode's
runtime-only hiding. Never expose a raw context temporarily and then claim
that hiding its source removes guest copies or image layers.
Guest-core path validation must accept the correctly filtered view, including
safe hidden-path substitutes, without restoring originals or relaxing host
validation just because an original is absent inside the VM.

Run QEMU and sharing/network helpers as the host user, with platform-specific
confinement restricting them to required files, handles, and network authority.
Bound the whole session's memory, CPU, process, and disk consumption, including
VM/helper overhead and sibling containers. Provide finite, reported VM budgets
separate from the existing development-container limits. No privileged host
launcher, broad home/device export, or silent software-emulation fallback.

### Network policy

Compose one effective allowlist on the host before project execution and give
that same policy to the outer proxy and managed guest core. Preserve current
composition: editor launches add the selected editor's bootstrap domains only
when configured `EGRESS_ALLOW` is nonempty; headless launches add none. An empty
list leaves external destinations unrestricted. Record the effective policy
and editor contribution in host-owned session state. Attachment operations
validate current project policy against it without dropping or rediscovering
editor additions; saved policy must not conceal configuration changes.

Block arbitrary physical-host services in every egress mode, including an
empty allowlist. Enforce this outside the guest for direct and proxied traffic,
covering host interface addresses, loopback aliases, and names resolving to
those destinations. Permit only the specific channels managed by jailbox.
Unrestricted egress must retain ordinary outbound protocols, not silently
become HTTP(S)-only access.

In filtered mode, enforce that policy outside the guest through a host-side
proxy. Preserve HTTP/HTTPS domain matching and CONNECT port restrictions. Guest
root, builds, sibling containers, alternate guest network modes, direct
IPv4/IPv6, and requests ignoring proxy variables must not bypass that policy.
Proxy or tunnel failure must leave access blocked. The guest's own proxy
sidecars must work through this outer proxy.

Establish the outer proxy and guest transport before core pulls or builds any
project, wrapper, or proxy image. Configure the guest engine service and build
execution independently of the inner sidecar, which does not exist yet. The
engine, build containers, and sidecars must each reach their configured proxy
endpoint; VM loopback alone does not provide that across container networks.
VM filtering also governs registry/package downloads that local host builds
currently perform outside the allowlist. Report denied required destinations
clearly; users must explicitly allow them, without an unfiltered fallback.
Document and test first launch with an empty image cache, including registry
authentication, redirects/CDNs, and wrapper package downloads. There is no
universal build-domain list for arbitrary development images.

Ship the outer proxy in the Go executable and run it as a separate confined,
managed process that survives the launching CLI. Use an existing HTTP/CONNECT
implementation with jailbox's policy checks and explicit outbound transport;
guest-controlled proxy settings must not redirect it. Retain Tinyproxy in
local and guest container sidecars. Core accepts the upstream endpoint through
a validated, declared, digest-covered input, empty by default for local use.
Readiness and reuse must verify the configured upstream. Inner frontend/test
composition passes that upstream explicitly while preserving each instance's
own allowlist and ordinary hardening; it must not inherit the parent's guest
profile or editor additions. Shared policy tests cover both implementations,
with the outer proxy also preventing arbitrary physical host-service access.
Replacing the existing sidecar implementation is outside this plan.

Inner jailbox instances may request different policies, including domains
needed by another editor under test; their effective access is still bounded
by the host policy. Tests needing those destinations must declare them in the
outer configuration. Policy and required helper changes require explicit
stop/relaunch and verified new host enforcement before attachment; guest
requests cannot change the host-approved allowlist.

### Guest preparation and container development

Download an authenticated, version-selected official Debian 13 cloud VM image
on demand, with native amd64 and arm64 variants. Ship a versioned preparation
recipe that installs the tested Podman stack, Bash/core dependencies, and
`jailcore` with its runtime assets, without requiring the Go frontend in the
base. The same recipe runs in CI and on user devices; record and check
actual dependency versions. No custom image download is required for initial
delivery, and no desktop or general development toolchain belongs in the base.

Preparation runs without project files, project code, or personal credentials.
Any network access needed for package installation is limited to that trusted
preparation phase and must not survive into project execution. Do not publish
a prepared cache entry until preparation, validation, and shutdown succeed.
Reuse only a clean template without instance credentials, machine identity,
project data, or prior guest-controlled changes. Refresh verified inputs and
recipes for security updates; do not upgrade a running session's engine.

Cache a clean immutable prepared base by guest architecture and verified image,
recipe, dependencies, and shipped core version/content identity. Reuse it across
projects and launches, with each project receiving its own writable disk layer
and fresh SSH identity.
Normal stop/start retains that project's disk and eligible persistent data;
cleaning a project retains the shared base. Never promote a used project disk
into a template. Updates create a new base version and explicitly migrate
project state between stopped sessions; never modify a base underneath its
existing project layers. Keep bases while project layers still reference them.
Retain recoverable original project storage until an upgrade is validated;
changing an overlay's backing file alone is not a guest OS upgrade.

Use a non-root guest account with working Podman user mappings and resource
control. Keep the development-image workflow: the selected development image
provides the user's tools, and a compatible Podman client reaches the one
guest engine through its socket. Containers created from that session are
siblings. No second engine or nested hardware virtualization is required.

Make this an explicit guest development profile in the core machine contract,
defaulting to ordinary hardening elsewhere. Allow only its specified guest
socket, shared bind-source paths, and guest network context; validate them at
creation, reuse, and attachment. Keep the non-root login, read-only container
root, dropped capabilities, and no-new-privileges. Socket access needs no
privileged container. Document that it nevertheless grants engine-user
authority within the VM and can bypass protections enforced only there.
The profile must not leak into ordinary containers created by jailbox's tests.

Preserve the developer's `tests/run` workflow from the editor terminal, using
local execution for containers under test rather than starting further VMs.
Execute the few engine-local test operations beside the guest engine, with
explicit transport where needed. Preserve their assertions, ownership checks,
output, exit status, and interruption behavior; a cancelled worker must not
continue mutating resources remotely. Test containers retain their requested
networks and mounts. Sharing a bridge alone does not satisfy existing
localhost-port assumptions: the development session must reach the guest's
published ports and inspect the socket tables and ephemeral range used by that
engine's port reservation. Preserve protection of unrelated guest listeners.

### Lifecycle

Serialize the frontend's dependent operations per project without changing
core's existing caller-coordination contract. Record the selected mode outside
the project; status and recovery use that ownership even when configuration is
invalid or selects a different mode. On upgrade, discover/adopt existing local
sessions through public core inventory when frontend ownership is absent;
failed inspection is not absence or permission to start a second environment.
Fresh VM-only installations still require no host Podman. Stop the active
environment before a mode switch; do not silently leave both modes running
against the same worktree or delete either mode's persistent data.
Local operations delegate to core with
their existing retention behavior. In VM mode, successful launch requires both
verified host enforcement and guest-core readiness before opening the editor
or publishing a usable connection. Reuse must match recorded project, policy,
guest recipe, and compatible component versions; stale or partial state cannot
silently become a healthy session.
Establish host restrictions before booting any project VM, including retained
guest state. Normal relaunch starts the managed session without automatically
resuming old sibling workloads. Retained guest-controlled startup files remain
untrusted; persistence is not a guarantee of fresh workload state.

In VM mode, `stop` removes the managed session through core when reachable,
terminates all remaining guest workloads by stopping the VM, and removes
session host helpers. Retain eligible persistent home and engine storage;
honor ephemeral home deletion. If the guest is unreachable, stop the VM and
revoke host access, report and record incomplete ephemeral cleanup, and
complete it before a new session can attach. Never claim deletion or discard
unrelated persistent storage to repair that failure. `--clean` removes the
project's VM disks and runtime state without modifying the host worktree or
another project's resources. Uninstall must not implicitly delete project disks.
Shared verified download caches have a separate lifetime.

Status remains read-only and distinguishes a stopped VM, an unreachable guest,
and incomplete resources. Validation does not download, provision, or boot a
VM. Stop/clean must remain usable with invalid project policy or a broken
guest; failed preparation, cancellation, and partial cleanup retain useful
diagnostics and never discard existing persistent data as an implicit repair.
An incompatible or unreachable guest core must not prevent host-side VM
shutdown, access revocation, or explicitly requested project cleanup.

### Acceptance and ordering

All three host OSs remain required for this specification's final acceptance;
a failed platform blocks completion, rather than authorizing its removal.
Before resuming, identify a maintained live-sharing mechanism for Windows and
a feasible verification setup for every advertised OS/CPU combination. Do not
assume Linux sharing helpers work on Windows. Record which checks run on
capable CI runners and which require reproducible manual runs, including how
release acceptance validates their commit, artifact, and dependency identities.
This deferred work does not add requirements to the Go migration's CI gates.

Prove the boundary before broad VM implementation. Start with a bounded
QEMU prototype using one synthetic worktree containing nested writable,
read-only, and hidden paths. Attack raw shares as guest root and through the
engine socket; verify actual host files independently. Then prove outer proxy
enforcement and failure behavior, followed by a representative sibling-engine
workload with builds, binds, volumes, localhost SSH, and engine-local helpers.
Include an already-occupied guest loopback port in the reservation check.
Repeat the host-boundary checks on macOS and Windows before committing to a
sharing implementation. Unsupported invariants do not justify a weaker
fallback. Include host-service denial with both empty and nonempty allowlists.

Final acceptance requires:

- Both modes use the same Go frontend and preserve configuration, editor,
  terminal, and failure-propagation contracts. Verify existing configurations
  without `RUNTIME`, explicit new-project defaults, unsupported local hosts,
  mode changes, and recovery after invalid or changed configuration. Local
  operation must not require or download QEMU or guest images.
  Cover adoption of pre-upgrade sessions and simultaneous projects using the
  same guest paths without host-state or editor-profile collisions.
- Verify guest `jailcore` without a Go frontend installed, unchanged machine
  records and lifecycle assertions, current-tree provisioning, and rejection
  of incompatible guest versions before dependent operations.
- Real accelerated Linux, macOS, and Windows runs, with exact host/CPU,
  guest/kernel, QEMU/helper, Podman, and editor versions recorded for every
  advertised combination. Cross-compilation and portable tests are not runtime
  evidence. Observe actual VMM/helper confinement and resource bounds on the
  host as well as testing attacks from the guest.
- The complete portable, runtime, matrix, and both-editor gates running from
  the VM development environment, with real sibling containers and unchanged
  assertion strength. Also verify actual host editor attachment, live file
  updates, and bootstrap on each supported host. Preserve local-mode coverage.
  Prove enforcement at the layer under test: the outer proxy must not make a
  broken inner restriction appear correct. Use controlled destinations that
  the outer policy allows and the inner policy denies where necessary.
  Prove allowed chained traffic and tunnel-loss denial from the engine, build
  steps, inner proxy, and development session, including editor bootstrap.
- Fresh installation/preparation, repeated launch, stop/relaunch, policy
  mismatch, resource exhaustion, guest/helper failure, interruption, upgrade
  compatibility, and clean/uninstall retention behavior. Verify base reuse
  across projects, private project writes, reference-aware cache retention,
  and rejected incomplete or unauthenticated runtime/image downloads. Include
  permission cases under 0022 and 0002 on applicable Linux guest/host paths.
- Native frontend tests on each supported host OS and VM integration belong
  in the existing gate and release workflow, without a fifth user-facing test
  mode. `runtime` owns VM security/sharing checks, `matrix` owns VM lifecycle
  and interruption checks, and `editor` owns host editor attachment; native Go
  checks remain in `portable`. Keep core and frontend lifecycle suites distinct
  within the matrix gate, with explicit contracts and fault scenarios for both.
  Skipped virtualization coverage does not pass acceptance. During
  implementation use dev and affected suites; run all gates for acceptance.
- User documentation covering mode selection, migration, setup, guest-engine
  authority, VM build masking, storage/cleanup, recovery, supported
  filesystems/platforms, and measured startup and filesystem costs. Measure
  small representative samples first.

A guest desktop, automatic file synchronization, multiple VM backends,
cross-architecture emulation, and running further hardware VMs inside this
guest are outside scope.

## Implementation detail

These are mechanisms to start from, not substitutes for the requirements above.

Extend the frontend in `src/host/frontend/`; keep guest runtime/provisioning
inputs under `src/`, maintenance tooling under `scripts/`, and verification
under `tests/`. Update `AGENTS.md` for frontend ownership of VM resources,
VM lifecycle contracts/fault coverage, platform verification, Windows
installation, and the explicit VM-only security profile. Retain Bash core
ownership and ordinary local hardening. Small shell/PowerShell installers
select verified platform artifacts; substantive setup belongs in Go.
Update `src/install.sh`, `scripts/build-tarball.sh`, release validation, and
installed layout tests to distribute native `jailbox`, Linux `jailcore` with
its runtime assets and version data, and provisioning inputs without bundling
guest disks or requiring a source toolchain on user devices. Local mode installs
core on the Linux host; VM mode installs it in the guest. Keep the core payload
independently usable within the coordinated release.
Publish the QEMU/helper runtime separately using an authenticated version and
platform manifest; publish complete cache entries atomically. Keep execution
paths small: local core invocation or VM preparation plus guest core invocation,
without a general plugin/provider framework.

Use QEMU's management protocol and existing SSH/filesystem/proxy implementations
where they satisfy the contract. Isolate platform-specific process supervision,
confinement, paths, and editor discovery. QEMU user networking with
`restrict=on`, a loopback SSH forward, and a fixed host-initiated reverse tunnel
to the outer proxy is a candidate for filtered mode; verify concurrent traffic
and destination confinement. A reviewed Go forward-proxy library supplies
HTTP/CONNECT handling; jailbox owns authorization and process lifetime.
Do not write a new filesystem protocol merely to keep every component in Go.
Stock sharing transports do not themselves implement the nested path policy.

Use an immutable base with per-project qcow2 backing layers. Use cloud-init
NoCloud with a small configuration disk for guest preparation and per-instance
initialization. The scripts in `debianimage/scripts/` are design input: replace
their installer-ISO reconstruction, fixed credentials,
MAC-derived networking, and KVM-only launch assumptions. Leave that user
experiment and its disk artifact untouched. Keep preparation identical whether
run by CI or the frontend; prepared-image distribution can be added separately
if measured setup cost warrants it.

Required integration with existing code:

- Extend the root `Containerfile` with the compatible Podman client and both
  editors' headless gate prerequisites for jailbox self-development. The Go
  toolchain is owned by `11.1-go-frontend-plan.md`; keep development tools out
  of the minimal guest base.
- Extend canonical declarations and generation in `src/public-api.sh` and
  `scripts/gen-public-api.sh` for VM settings and guest-core inputs, including
  conformance checks. Core retains Linux path resolution. Host export has a
  distinct job: apply the same declared policy to physical-host objects before
  sharing. Use shared policy fixtures to prevent precedence/anchor drift.
- Make `start_jailbox_container`, `validate_container_hardening`, and
  `validate_development_mounts` in `src/host/core/resources/container.sh`, the
  network checks in `src/host/core/resources/network.sh`, and
  `src/container/checks/validate-session.sh` validate the explicit guest profile
  instead of bypassing ordinary checks. Preserve exact ordinary-profile tests.
- Adapt `src/host/core/resources/proxy.sh` and
  `src/container/tinyproxy/tinyproxy.conf` for verified upstream chaining.
  Extend the public connection data produced by
  `src/host/core/commands/connection-info.sh` as needed; retain its framing,
  required fields, trailing-field compatibility, and version policy. The
  Go consumer established by `11.1-go-frontend-plan.md` must retain its
  validation and trailing-field behavior when adding guest transport.
- Adapt engine-local operations in `tests/lib/lifecycle-runtime.sh` and
  `tests/lib/lifecycle-fixture.sh`, and port observation in
  `tests/lib/fixture-ports.sh`; preserve fault injection and cancellation
  guarantees in `tests/lib/lifecycle-fault.sh` and
  `tests/lib/lifecycle-runtime-faults.sh`. Separate VM frontend lifecycle tests
  from core's declaration-derived lifecycle matrix.
- Extend `.github/workflows/test-gates.yml` and packaging checks for the new
  artifacts and real VM coverage. Update README, development/automation/security
  guides, and architecture documentation for the shared frontend, mode
  selection, and VM mode's different outer trust boundary.

Saved results in `testlog/machine-probe.*` provide bounded Linux evidence that
host-side read-only sharing resists guest-root remount writes. Separate
writable, read-only, and empty exports do not prove a nested project view,
host-process confinement, or filtered VM networking. Retain those results;
the acceptance checks above own verification of the implemented design.

Reference mechanisms, to verify against selected versions:

- [QEMU security and host confinement](https://www.qemu.org/docs/master/system/security.html)
- [QEMU networking](https://www.qemu.org/docs/master/system/invocation.html)
- [QEMU disk backing images](https://www.qemu.org/docs/master/system/images.html)
- [Go HTTP/CONNECT proxy library candidate](https://github.com/elazarl/goproxy)
- [Cloud-init NoCloud](https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html)
- [Podman API authority](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)
- [Podman unshare limitations](https://docs.podman.io/en/latest/markdown/podman-unshare.1.html)
