# Core resource verification

Core commands compose resource observations and explicit operations. Resource
modules own detailed checks; compatibility and attachment modules coordinate
them. Inventory, launch compatibility, and attachment readiness are distinct:
`status` does not need healthy credentials, and recovery does not need valid
launch configuration. Tests call production resource helpers with independently
specified fixture expectations. No public state protocol is added.

## Coverage inventory

This maps the pre-migration assertions to their current owners. Existing
concrete defects, lifecycle rows, mutation discovery, and recovery assertions
remain scheduled. Repeated exec/shell observations in discovered interruption
sweeps are consolidated. SSH defects still prove their own refusal and repaired
baseline; metadata and key-content representatives supply the final relaunch
proof for equivalent contracts. The cases themselves are not removed.

| Contract / previous assertion | Current evidence |
|---|---|
| Resource absence, fresh inventory, failed producers with plausible output, exact status framing | `unit/resource-inventory.sh`, `unit/resource-detection.sh`, `unit/machine-inventory.sh`, all matrix status observations |
| Running versus stopped versus unsupported container state; structure, hardening, mounts, and failed inspections | `unit/resource-detection.sh`, `unit/convergence.sh`, `unit/validation-batches.sh`, runtime security, constructed matrix and health variants |
| Ordinary/internal/external network suitability, attachment identity, recreated networks, unrelated members, subnet collision | `unit/network.sh`, `unit/network-attachments.sh`, `unit/convergence.sh`, corresponding matrix rows and runtime egress |
| Persistent/ephemeral/legacy/empty/corrupt/newline home metadata, ownership, data retention and recovery precedence | `unit/resource-detection.sh`, `unit/lifecycle.sh`, all home and combined-defect matrix rows; marker assertions before/after interrupted recovery |
| SSH metadata, key pairs, authorization, pin, receipt binding, staged/orphaned state and unsafe paths | `unit/ssh-generation.sh`, `unit/project-state.sh`, `unit/ssh-config.sh`, all SSH defect matrix refusals/cleanup, explicit metadata/key-content relaunch representatives, interruption credential snapshots |
| Runtime files, safe publication, cleanup ownership and failure propagation | `unit/runtime-mounts.sh`, `unit/lifecycle-git.sh`, `unit/test-cleanup.sh`, existing fault-role requirements and interrupted cleanup assertions |
| Effective filter equivalence, configuration file safety and live SSH proxy delivery | `unit/network.sh`, `unit/ssh-generation.sh`, `unit/ssh-session.sh`, runtime egress, editor task inheritance |
| Images, mutable references versus immutable IDs, digest compatibility, protected build inputs | `unit/config-digest.sh`, `unit/readonly-paths.sh`, `unit/convergence.sh`, runtime mounts and lifecycle cleanup |
| Required connection validation, refusal framing and absence of mutation | All constructed and interrupted/recovered matrix connection observations; `unit/connection-observer.sh`, `unit/attachment.sh` |
| Exec and shell delegate to the same attachment boundary and refuse before execution | `unit/exec.sh`, `unit/shell.sh`; all constructed-state and targeted-failure matrix exec/shell observations |
| Exec binary stdin and shell PTY behavior previously repeated at every interruption | Constructed-state/targeted matrix observations retained; `running.up` transport and concurrent exec tests; headless argv/stdin/exit/terminal/signal coverage. Interruption sweeps retain connection-info's full shared validation instead of repeating it through both transports. |
| Healthy creation/reuse/resume; persistent and ephemeral stop/relaunch; clean/relaunch | Existing constructed-state matrix command cases and every interrupted recovery sequence |
| Interrupted launch/stop/clean, failed rollback/removal, surviving dependencies, exact identities, unrelated resources, data and retryability | All discovered before/after/barrier cases remain; independent operation-role floors in `lib/lifecycle-contracts.sh`, fixture snapshots/marker assertions and real recovery remain unchanged |
| Observer effectiveness and missing coverage | `unit/lifecycle-observer.sh`, `unit/lifecycle-recovery.sh`, `unit/connection-observer.sh`, `unit/exec-observer.sh`, `unit/shell-observer.sh`, `unit/lifecycle-matrix.sh`, `unit/lifecycle-pool.sh`; wrong-classification, suppressed-refusal, missing-operation and malformed-producer negative controls |
| Public declarations, source/installed dispatch, nested layout, packaging and recursive installation | Portable declaration/dispatch/boundary/distribution suites, `unit/core-layout.sh`, `unit/bundle-install.sh` |

## Observation workloads

Constructed states, health variants and targeted failures retain full status,
connection-info, exec and shell observations. Discovered interruption cases use
status and connection-info before and after recovery. Their expected attachment
outcome remains independently determined from surviving fixture resources and
service evidence, not from connection-info's result. Their cleanup/relaunch,
markers, identities, and dependencies are still checked at every point.

Observation artifacts identify the workload used. Unknown workloads fail
explicitly. The portable observer test verifies both workload selection and
that a failed required readiness check cannot publish a successful observation.
The case catalog and sample selection remain intact; counts describe actual
refusal/repair cases, not a claim that every case performs a complete relaunch.
`recovery-coverage` records which representative supplies a shared relaunch proof.
Every grouped defect must independently establish absence of containers,
networks, and credentials, preserved home contents and labels, and retained
unrelated runtime content. The representative must be selected and have the
same complete row contract; missing or non-equivalent representatives fail.
The 50-case sample contains no grouped SSH rows and its workload is unchanged.
The 150-case sample includes them and now has a changed workload: establish a
new baseline or compare exactly shared work, not just identical case names.

## Measurement and acceptance

Compare the unchanged 50-case workload with worker count, host limits, and image
preparation held fixed. Measure bounded fault jobs separately for the changed
interruption workload. Use a warm-up and repeated runs to report the spread and
work avoided. The 150-case sample needs a new baseline or an exact shared-work
comparison because its recovery workload changed.

Acceptance requires portable coverage on Linux, macOS, and Bash 4.4,
permission-sensitive checks under both `0022` and `0002`, the runtime and matrix
gates, and both real editor clients. Coverage listed here is not a claim that a
gate or platform passed. Run results, environment limitations, timing evidence,
and local log locations belong in the handoff.
