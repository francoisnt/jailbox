# 11. Optional nested Podman inside krun

## Intent

Let users run a real local Podman engine inside a krun-backed jailbox, including
jailbox's existing integration tests. Test scripts, engine storage, and published
ports share the guest environment. No remote engine bridge, host engine socket,
or separate test VM is required.

Depends on `10-krun-namespace-isolation-plan.md`. Plan 10 owns the early evidence
that guest engine privileges and host VMM confinement can coexist. This plan's
implementer owns integrating that evidence into the public capability, guest
provisioning, lifecycle checks, documentation, and complete test verification.

### Public behavior

- Add the machine boolean `NESTED_PODMAN`, default `false`, through the public
  declarations. File configuration uses the same key and machine callers use
  `JAILBOX_CONFIG_NESTED_PODMAN`. Include it in schema, validation, frontend
  composition, configuration digest, and release-version review.
- Accept `true` only with explicit `DEV_RUNTIME=krun`. Reject other combinations
  before resource mutation. Selecting krun alone does not enable the capability
  or relax guest restrictions. Missing prerequisites cause explicit failure;
  never use the host engine or silently disable isolation.
- When enabled, `podman` in the normal development session is the guest's local
  CLI and engine. Provide working image builds, bind mounts, managed volumes,
  container networking, loopback port publication, and `podman unshare`.
  Preserve arguments, streams, exit status, and ordinary local process semantics.
- Provision required engine packages and guest configuration during trusted
  preparation. Do not require per-session manual privilege changes. Ordinary
  mode must not acquire these dependencies or permissions.
- Capability changes require explicit stop/up. Reuse and attachment verify
  actual guest readiness and host containment, without repairing either during
  attachment. Report unavailable engine state as a failed readiness check.
- Store writable engine state in guest-managed storage with documented lifetime:
  retain reusable images and volumes with a persistent home; remove them with
  an ephemeral home or explicit clean. Stopping the outer sandbox terminates
  inner workloads; a new outer generation must not automatically restart them.
  Disabling the capability may retain stored data but must not retain the
  authority or launch behavior that enables the inner engine.

### Security boundary

This capability explicitly permits the guest authority required for nested
containers, including controlled exceptions to ordinary guest capability and
no-new-privileges policy where the verified implementation needs them. Document
the actual exceptions and assume the agent can control the guest engine and
its resources. Keep the normal development login non-root where feasible;
guest engine access must never be presented as an unprivileged security boundary.

Retain plan 10's host-side restrictions. No privileged outer container, host
engine socket, broad host device access, or host namespace sharing is permitted.
Only the host-authorized filesystem view reaches the guest, with read-only and
hidden protections enforced outside guest control. Inner mounts cannot expose
additional host files or weaken those protections. Guest-owned writable storage
must not make a host-shared read-only root writable.

Filtered egress remains enforced outside the guest-controlled engine. Inner
containers, builds, DNS, and alternate networking modes cannot obtain an
external route bypassing the outer proxy policy. Preserve the existing stated
host-service and allowed-destination limitations. Host resource limits bound
the complete guest workload, including all inner containers, image storage, and
builds; document and bound disk consumption without silently discarding data.
Do not add another nested-engine socket to ordinary jailbox sessions.

Nested containers do not require nested hardware virtualization. This plan
supports ordinary inner runtimes, not krun/Kata inside krun, GPU passthrough,
or guest access to host KVM. It does not claim that krun-mode tests can themselves
run inside this guest without a separately supported virtualization capability.

### Acceptance

Use plan 10's recorded host/guest feasibility evidence and verify the selected
versions again under the complete feature. If the required separation is not
achievable, report the blocker rather than broadening host authority.

Run the existing portable, runtime, matrix, and both-editor gates from within
the enabled jailbox with the real guest-local Podman. Individual test suites
retain their existing calls and assertions: no remote dispatch, weaker checks,
or test-specific fake engine. Provision the normal test image with its editors,
display support, and other test dependencies; the product capability itself
does not require editors. Preserve native-host and ordinary-krun gate coverage.

Verify engine creation/build/run/unshare and cleanup, UID/GID ownership and
permissions under 0022 and 0002, local SSH port use, resource-limit behavior,
and existing interruption/recovery cases. Prove from inner containers that
host file protection and filtered egress cannot be bypassed. Cover enable/disable,
resume/recreation, persistent and ephemeral storage, guest engine failure, and
outer interruption without host-side orphan resources. Inner-container checks
must not substitute for independent observation of the host VMM boundary.

Integrate these checks into the existing shared CI and release gates on a
KVM-capable host, without another user-facing test mode. Document supported
host/guest combinations and measured startup/storage costs. No skipped or
sampled gate constitutes complete acceptance.

## Implementation detail

Prefer the minimum guest provisioning supported by the verified krun stack;
use a guest filesystem suitable for container storage rather than assuming
the VM's shared filesystem supports every storage driver. Keep installation
and guest helpers in the existing container source layout and host policy in
core; the frontend only composes public configuration.

Extend the host/guest checks established by plan 10 to select the exact policy
for each mode. Ordinary guest hardening assertions remain intact when disabled.
Keep the outer proxy independently controlled and distinguish guest-local
loopback from the physical host's loopback in documentation and tests.

Provision test dependencies through the existing test-image and gate setup
mechanisms. Start with the plan 10 prototype, then exercise representative
filesystem, SSH, and interruption cases before the complete acceptance runs.
Include new runtime artifacts in packaging and installed-layout checks.
