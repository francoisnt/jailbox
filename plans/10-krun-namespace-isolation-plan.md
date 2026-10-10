# 10. krun with host namespace isolation

## Intent

Add optional krun execution for the development sandbox. The agent runs on a
guest kernel while the host process running that VM remains confined by
Podman's namespaces, filesystem policy, and privilege restrictions. A guest
kernel compromise must not grant ordinary access to the host user's files or
network. Preserve the existing development and automation workflows.

This plan takes ownership of the krun investigation in `backlog.md`, including
implementation and verification. Other VM runtimes and a separately managed
VM enclosure remain outside this plan.

Eventual macOS support is a product goal, tracked in `backlog.md`. This plan's
acceptance remains Linux-only; the Mac VM boundary requires separate design
and verification when a suitable test host is available.

### Public behavior and scope

- Add the machine scalar `DEV_RUNTIME=default|krun`, defaulting to `default`.
  File configuration accepts the same key; machine callers use
  `JAILBOX_CONFIG_DEV_RUNTIME`. `default` preserves existing runtime selection
  and behavior. Declare the key through the canonical public API so schema,
  parsing, frontend composition, digest, and release-version review include it.
- `krun` explicitly selects the krun development runtime. Initially support
  local rootless Podman on Linux with usable KVM and a verified runtime stack.
  Reject rootful, remote-engine, and unsupported-platform krun launches with
  actionable diagnostics. Do not install dependencies, elevate privileges,
  change host configuration, or silently fall back to ordinary containers.
- Only the development sandbox gains the VM boundary. In krun mode, select a
  verified conventional runtime explicitly for the existing proxy sidecar.
  Image builds and development-image probes remain trusted host-engine
  operations outside the VM guarantee; document this before launch examples.
- Runtime selection participates in configuration compatibility. Changing it
  requires explicit stop/up and retains an eligible persistent home. Verify
  actual runtime identity as well as matching labels before reuse, resume,
  or attachment. Preserve caller serialization, SSH generation, and recovery
  contracts. Inventory and cleanup must not require working KVM or krun just
  to inspect/remove resources; report engine removal failures accurately.
- `validate` checks syntax and local prerequisites without starting a VM or
  creating sandbox resources. `up` establishes live readiness; connection-info,
  exec, shell, and editor attachment must refuse unverifiable containment.
  Keep existing machine record formats unchanged.

### Isolation contract

Use host namespaces around the VM process, not merely namespaces inside the
guest. The host-side virtual machine monitor (VMM), filesystem service, and
network helpers are part of the boundary and must be accounted for.

| Boundary | Required result |
|---|---|
| Mounts | The VMM sees the prepared sandbox root and authorized mounts, never the host root or personal home. Read-only overlays, writable exceptions, hidden paths, private propagation, and SSH authentication protection remain effective at the host sharing boundary. |
| Network | Guest traffic and any forwarding helpers use the intended confined network context. Filtered mode retains no direct external route and permits outbound HTTP(S) only through the existing allowlisting proxy. |
| Identity | Host execution stays rootless with bounded UID/GID mappings; the development workload retains the non-root managed identity and correct project/home ownership. |
| Processes and IPC | Host-side sandbox processes have isolated PID, IPC, and UTS contexts and cannot join host namespaces. Guest identity alone is not evidence of this isolation. |

Preserve the read-only root, dropped capabilities, no-new-privileges, and absence
of host container-engine sockets. Ordinary krun mode retains guest workload
restrictions too. Keep host and guest enforcement distinct so the explicit
nested-Podman capability in `11-nested-podman-plan.md` can grant guest-side
authority without weakening host confinement. Account explicitly for runtime-required KVM
handles; they must not expose host device access to the development workload.
Do not permit privileged execution, broad device mounts, host networking, or
disabled security controls to make krun start. Inherited descriptors must not
provide an alternate route to unshared files, sockets, or namespace handles.
Preserve applicable seccomp and SELinux enforcement; verify the actual host and
guest protections rather than treating recorded flags as proof.

The guest may access only the files authorized by existing path policy, even
through the VM's filesystem service. Preserve existing hardlink, host-race,
build-context, and persistent-home limitations rather than claiming to solve
them. The current warning about bridge-reachable host services still applies;
this feature does not promise stronger host-service filtering.

Enforce existing CPU, memory, and process limits at their meaningful layers:
host limits bound VMM/helper resource consumption and guest limits bound the
development workload. Host VMM thread counts are not guest process counts.
Account for VM overhead and reject unsupported settings rather than ignore
them. Image-provided VM configuration must not override jailbox's resource or
security policy. Do not expose arbitrary runtime flags, custom kernels, GPU
passthrough, nested virtualization, or confidential-computing modes.

### Acceptance and delivery

Establish a tested Linux/architecture/Podman/crun/libkrun/libkrunfw combination
before exposing krun as usable. Audit its initialization and sharing behavior;
record versions and evidence. If upstream cannot preserve a required invariant,
the feature remains blocked: do not weaken the invariant or report completion.
Establish this early with a bounded integration prototype, before broad CLI work.

Before completing this plan, verify that the chosen stack can grant guest-side
authority for an inner Podman engine while retaining the host namespace,
mount, network, and privilege boundary. The bounded probe must create and remove
an ordinary inner container, exercise a bind mount and `podman unshare`, and
record the required guest permissions and remaining compatibility limitations.
This plan owns that feasibility evidence; `11-nested-podman-plan.md` owns the
public capability, guest provisioning, lifecycle integration, and unchanged-suite
verification. Do not expose nested Podman through ordinary krun selection.

Acceptance must include independent host observations of the actual VMM/helper
namespaces, filesystem root, mappings, privileges, and retained descriptors,
plus guest behavior. A guest kernel name, requested runtime flag, or Podman
configuration record alone does not prove the boundary. Missing or failed
required observations prevent readiness and attachment without publishing a
connection or starting a user command; read-only checks never repair state.

Real tests must prove protected/hidden host content survives guest access
attempts, authorized writes reach the correct project/home, and paths outside
the share remain inaccessible. Cover nested path precedence, SSH authentication,
non-root execution, resource-limit enforcement, and proxy allowed/denied traffic,
including direct IPv4/IPv6 attempts that ignore proxy variables. Test boundary
observations against deliberately invalid fixtures so checks cannot pass merely
because the same code produced the expected answer.

Cover fresh launch, healthy reuse, stop/resume, runtime-policy mismatch,
missing KVM/runtime, interrupted VM startup, retained dependencies, cleanup,
and home preservation. Preserve ordinary-runtime coverage. Run portable plus
the complete runtime, lifecycle matrix, and both-editor gates for the supported
krun configuration; integrate coverage into the existing shared CI gates and
release verification, without another user-facing test mode. Provision a
KVM-capable test host: skipped virtualization jobs do not count as passing.
Use dev and affected suites during implementation, including permission cases
under both 0022 and 0002.

Document installation prerequisites, supported versions/platforms, opt-in use,
recovery, and the two isolation layers. Explain that writable shares and allowed
destinations remain usable for damage or data disclosure. Record short matched
startup, memory, and filesystem-workload measurements against the ordinary
runtime; claim only measured compatibility and cost. This plan owns ordinary
krun integration and acceptance, including the feasibility handoff above; nested
Podman becomes available only after plan 11 completes its acceptance criteria.

## Implementation detail

Prefer Podman's krun integration and existing namespace machinery over a new
launcher or VM manager. Core owns runtime policy, prerequisite checks, resource
operations, and cross-resource validation; the frontend only composes the public
configuration. Keep optional-runtime dependencies out of ordinary-mode checks.
Temporary probes need isolated resources and operation-owned cleanup.

Migrate the single-kernel assumptions in `validate_container_hardening` and
`validate_development_identity` in `src/host/core/resources/container.sh`, and
the mount, process, and route checks in `src/container/checks/validate-session.sh`
and `src/container/runtime/lib/jailbox/process-hardening.awk`. Guest mountinfo
may describe virtiofs rather than individual host overlays, guest PID 1 may be
VM init, and guest routes may not describe socket forwarding. Replace those
assumptions with evidence at the layer enforcing each property; keep the
ordinary-runtime checks intact. Extend the shared attachment boundary instead
of adding weaker krun-only paths to individual commands.

Audit runtime selection across creation, inspection, and stopped-resource
recovery, including the proxy. Bind live host observations to the engine's
actual process identity and reject vanished/replaced processes. Do not require
unchanging namespace inode numbers across legitimate resume. Exercise installed
and checkout layouts and keep generated API/documentation consumers complete.

Sources checked on 2026-10-09; verify behavior against the versions selected
for implementation rather than assuming upstream main matches installed code:

- [krun runtime and configuration](https://github.com/containers/crun/blob/main/krun.1.md)
- [libkrun security model](https://github.com/libkrun/libkrun#security-model)
- [crun krun handler](https://github.com/containers/crun/blob/main/src/libcrun/handlers/krun.c)
