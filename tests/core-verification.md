# Core resource verification

Core commands compose resource observations and explicit operations. Resource
modules own detailed checks; compatibility and attachment modules coordinate
them. Inventory, launch compatibility, and attachment readiness are distinct:
`status` does not need healthy credentials, and recovery does not need valid
launch configuration. Tests call production resource helpers with independently
specified fixture expectations. No public state protocol is added.

## Coverage inventory

Portable suites are identified by globally unique basenames; find their files
under `tests/unit/` or recursively under `tests/harness/`.

This maps the pre-migration assertions to their current owners. Existing
concrete defects, lifecycle rows, mutation discovery, and recovery assertions
remain scheduled. Repeated exec/shell observations in discovered interruption
sweeps are consolidated. SSH defects still prove their own refusal and repaired
baseline; metadata and key-content representatives supply the final relaunch
proof for equivalent contracts. The cases themselves are not removed.

| Contract / previous assertion | Current evidence |
|---|---|
| Resource absence, fresh inventory, failed producers with plausible output, exact status framing | `resource-inventory.sh`, `resource-detection.sh`, `machine-inventory.sh`, all matrix status observations |
| Running versus stopped versus unsupported container state; structure, hardening, mounts, and failed inspections | `resource-detection.sh`, `convergence.sh`, `validation-batches.sh`, runtime security, constructed matrix and health variants |
| Ordinary/internal/external network suitability, attachment identity, recreated networks, unrelated members, subnet collision | `network.sh`, `network-attachments.sh`, `convergence.sh`, corresponding matrix rows and runtime egress |
| Persistent/ephemeral/legacy/empty/corrupt/newline home metadata, ownership, data retention and recovery precedence | `resource-detection.sh`, `lifecycle.sh`, all home and combined-defect matrix rows; marker assertions before/after interrupted recovery |
| SSH metadata, key pairs, authorization, pin, receipt binding, staged/orphaned state and unsafe paths | `ssh-generation.sh`, `project-state.sh`, `ssh-config.sh`, all SSH defect matrix refusals/cleanup, explicit metadata/key-content relaunch representatives, interruption credential snapshots |
| Runtime files, safe publication, cleanup ownership and failure propagation | `runtime-mounts.sh`, `lifecycle-git.sh`, `test-cleanup.sh`, existing fault-role requirements and interrupted cleanup assertions |
| Effective filter equivalence, configuration file safety and live SSH proxy delivery | `network.sh`, `ssh-generation.sh`, `ssh-session.sh`, runtime egress, editor task inheritance |
| Images, mutable references versus immutable IDs, digest compatibility, protected build inputs | `config-digest.sh`, `readonly-paths.sh`, `convergence.sh`, runtime mounts and lifecycle cleanup |
| Required connection validation, refusal framing and absence of mutation | All constructed and interrupted/recovered matrix connection observations; `connection-observer.sh`, `attachment.sh` |
| Exec and shell delegate to the same attachment boundary and refuse before execution | `exec.sh`, `shell.sh`; all constructed-state and targeted-failure matrix exec/shell observations |
| Exec binary stdin and shell PTY behavior previously repeated at every interruption | Constructed-state/targeted matrix observations retained; `running.up` transport and concurrent exec tests; headless argv/stdin/exit/terminal/signal coverage. Interruption sweeps retain connection-info's full shared validation instead of repeating it through both transports. |
| Healthy creation/reuse/resume; persistent and ephemeral stop/relaunch; clean/relaunch | Existing constructed-state matrix command cases and every interrupted recovery sequence |
| Interrupted launch/stop/clean, failed rollback/removal, surviving dependencies, exact identities, unrelated resources, data and retryability | All discovered before/after/barrier cases remain; independent operation-role floors in `lib/lifecycle-contracts.sh`, fixture snapshots/marker assertions and real recovery remain unchanged |
| Observer effectiveness and missing coverage | `lifecycle-observer.sh`, `lifecycle-recovery.sh`, `connection-observer.sh`, `exec-observer.sh`, `shell-observer.sh`, `lifecycle-matrix.sh`, `lifecycle-pool.sh`; wrong-classification, suppressed-refusal, missing-operation and malformed-producer negative controls |
| Public declarations, source/installed dispatch, nested layout, packaging and recursive installation | Portable declaration/dispatch/boundary/distribution suites, `core-layout.sh`, `bundle-install.sh` |

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
The 50-case sample contains no grouped SSH rows. Its running and stopped rows
now exercise directory and file-only writable policies, and running.up includes
writable-permission and undeclared-overlay health variants. Both samples need
a new performance baseline for this workload.
The 150-case sample includes them and now has a changed workload: establish a
new baseline or compare exactly shared work, not just identical case names.

## Measurement and acceptance

Compare the same 50-case workload revision with worker count, host limits, and image
preparation held fixed. Measure bounded fault jobs separately for the changed
interruption workload. Use a warm-up and repeated runs to report the spread and
work avoided. The 150-case sample needs a new baseline or an exact shared-work
comparison because its recovery workload changed.

Acceptance requires portable coverage on Linux, macOS, and Bash 4.4,
permission-sensitive checks under both `0022` and `0002`, the runtime and matrix
gates, and both real editor clients. Coverage listed here is not a claim that a
gate or platform passed. Run results, environment limitations, timing evidence,
and local log locations belong in the handoff.

Writable-path coverage uses existing matrix row names: running exercises a
directory lane with alternating read-only/writable descendants and repeated
entries, stopped resumes a file-only lane, and
mismatched-digest changes writable policy before explicit recovery. The retained
home launch fault fixture uses a writable exception inside a read-only child
of a directory lane; its SSH launch probe is a
required fault boundary. Snapshot selection stays bounded: the two new health
variants add four comparisons, increasing the fixed total from 36 to 40. Selected
snapshots include the small project fixture to catch attachment mutations.
Portable `writable-paths`, `validation-batches`, `attachment`, and schema-consumer
checks cover rejection and read-only observation; runtime wrapper checks prove
kernel enforcement, regular-file writes and protected Git commits. Effective
path-policy coverage adds repeated alternation, automatic file protection inside
an exception, silent overlap suppression and user-managed symlink destinations.
These extensions retain existing row counts and bounded snapshot selections;
earlier timing samples do not measure the expanded workload.

Hidden-path coverage extends the same running/stopped rows with native file and
ancestor masks. Three health variants remove masks or add unauthorized overlays
at/below masked destinations, including a foreign source at an exact file mask.
Their six before/after comparisons bring the bounded snapshot total to 46.
Fresh-home and retained-home launch interruption fixtures include masks, so
native creation failure and subsequent cleanup use the existing fault sweep without new rows.
The 50- and 150-case samples retain their selections but need new performance
baselines for this expanded workload. Portable hidden-path and attachment checks
cover policy/refusal and batched inspection; runtime fixtures build selected
Containerfiles before masking and assert hidden contents, denied deletion and
replacement, writable siblings, readable aliases, and unchanged host contents.
