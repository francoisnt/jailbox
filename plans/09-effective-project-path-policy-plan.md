# 9. Effective project path policy

## Intent

Build on `07-writable-paths-plan.md` and `08-hidden-paths-plan.md` so configured
paths obey one precedence policy. Users configure symlink destinations according
to the access they want; jailbox does not infer policy from links.

### Precedence and validation

Cross-category overlaps are valid. Resolve policy in this order:

1. A hidden path or ancestor masks the path and suppresses descendant overlays.
2. Automatic protection remains read-only unless hidden; configured writable
   entries cannot override it.
3. Among configured read-only and writable entries covering a path, the most
   specific entry wins. Read-only wins if both lists contain that exact entry.
4. Otherwise, use the project base policy.

For example, read-only `src` with writable `src/generated` permits writes in
`src/generated` while other contents of `src` remain read-only. A read-only
`src/generated/policy` restricts that child again. Resolve by path specificity,
not array order. Suppression is normal composition: emit no overlap errors or
warnings, including when automatic protection suppresses a writable entry.

Validate every explicit entry before suppressing it. Preserve existing lexical,
existence, regular-file/directory, physical-project containment, and
no-symlink-component rules. Reject duplicates within each array, but allow
nested read-only and writable entries so alternating exceptions can be
expressed. Preserve the rejection of nested hidden entries. Preserve automatic protection of
selected Containerfiles and frontend configuration. A hidden mask satisfies
their runtime integrity requirement after the host consumes them.

The project base is read-only whenever the configured writable array is
nonempty, even if stronger restrictions suppress every writable lane.

### Symlinks

Do not walk configured directories to discover or validate contained symlinks.
Links do not propagate restrictions or permissions, require target coverage,
or add mounts. Their destinations retain the policy applied at the accessed
pathname, including the project base when no entry covers it. Users are
responsible for configuring destinations they want read-only, writable, or
hidden. Intermediate link directories receive no implicit protection.

For example, making `src` read-only does not protect an otherwise writable
target reached through `src/link`. Hiding a directory does not hide its linked
destinations elsewhere. Conversely, a symlink to an already masked pathname
does not bypass that mask. Links to outside paths do not introduce host mounts.

Contained broken, cyclic, external, or project-root links do not cause launch
or attachment refusals. Keep the no-symlink-component and existence checks on
the explicitly configured paths themselves, and preserve the separate rules
for trusted build inputs. Removing automatic target protection changes the
existing read-only integrity contract and must be documented.

### Runtime contract and acceptance

Resolve effective policy deterministically for validation, launch, and
attachment. Contained link creation or retargeting alone does not require
recreation or block attachment. Configuration changes still require explicit
stop/up through existing digest compatibility checks; never repair resources
during attachment. Preserve configuration digest semantics and read-only
attachment checks.

Use native masks and private project mounts. Writable child overlays are valid
only where effective policy permits them; no overlay may re-expose hidden
contents or weaken automatic protection. Validate the complete mount
inventory and live mask behavior, retaining checks on sources, types,
permissions, propagation, and unexpected mounts.
Parent mounts must be established before descendant overlays so they cannot
obscure configured child exceptions, independent of category or array order.

Mask names may remain discoverable and native substitutes may accept empty
reads or discarded writes. Original content remains inaccessible and unchanged
through masked paths. Independent hardlinks/copies do not inherit restrictions;
runtime masking does not exclude files from build contexts. Other sandbox
security invariants remain unchanged.

Acceptance covers exact and ancestor overlaps for every category combination,
including all three at once. Verify that contained symlinks neither add policy
nor cause refusals, including broken/cyclic links and links to external paths
or the project root. Preserve tests that reject symlink components in explicit
configuration entries and show that runtime symlinks cannot bypass masks.
Cover read-only parents with writable children, the reverse, and repeated
alternation across several levels, independent of array order. Verify exact
read-only/writable ties and absolute hidden/automatic protection, including
automatic file protection inside a writable exception.
Verify that all suppressed writable lanes still leave the base read-only,
changed effective policy refuses reuse/attachment, and real containers cannot
write paths whose effective policy is read-only or read/change original hidden
content. Prove writable exceptions work while their read-only siblings remain
protected. Validate the new nested mount combinations with Podman early in
implementation. Assert that valid cross-category overlaps succeed without
overlap warnings, including a writable
declaration for the automatically protected frontend configuration file.

### Non-goals

Do not add symlink discovery, coverage enforcement, propagation, diagnostics,
or configuration modes; potential symlink tooling is deferred to `backlog.md`.
Do not add a persistent policy cache or a general-purpose policy engine, hide
path names, or extend masking to build contexts, independent hardlinks, or copies.

## Implementation detail

Prefer one operation-local effective policy result shared by mount generation,
inspection, allowed-mount inventory, and streamed session checks. Suppress
redundant or overridden overlays only after validating the full configuration.
Retain nested entries that restore a policy below an exception; an entry is
not redundant merely because an ancestor has the same category.
Keep configuration arrays unchanged and publish no partial effective result
on failure.

Migrate the read-only-only expansion and overlap rejection in
`src/host/core/resources/container.sh`, including
`finalize_effective_readonly_paths` and `validate_writable_path_policy`. Remove
automatic expansion through `expand_readonly_symlink_targets` and remove its
unused closure helpers. Remove `project_symlink_dependencies` and
`print_project_protection_target` in `src/host/core/project/paths.sh`, including
their contained-link refusal diagnostics. Replace the conflict decision in
`writable_path_conflicts_with_protection` with the new precedence rules.
Replace nested-writable rejection in `validate_writable_paths_lexical` in
`src/host/core/configuration/load.sh`, retaining duplicate rejection and the
hidden-array validation rules. Preserve frontend configuration-file anchors
composed by `src/host/frontend/file-policy.sh`: these regular-file entries remain
protected by the exact-path read-only tie rule, including inside writable
directories. Selected Containerfile protection must likewise survive all
configured exceptions.
Replace scattered precedence decisions in mount creation
and `validate_development_mounts` in `src/host/core/resources/container.sh`, and
in `validate_development_session` in `src/host/core/resources/ssh.sh`, with the
effective result. Keep the exact-mount checks in
`src/container/checks/validate-session.sh` and
`src/container/runtime/lib/jailbox/readonly-mount.awk` working with nested
mounts; preserve hidden-mask descendant rejection. Host mount inventory must
reject overlays not authorized by effective policy. Replace the category-order
assumption and non-nesting comment in `build_readonly_mounts`; extend the
ordering assertions in `tests/unit/runtime-mounts.sh` for both nesting
directions and repeated alternation.

Replace overlap-error expectations in `tests/unit/writable-paths.sh`,
`tests/unit/hidden-paths.sh` (the writable/protected conflict, not nested hidden
entries), `tests/unit/convergence.sh`, and
`tests/lib/check-schema-consumer.py`. Extend those path-policy suites and
`tests/unit/readonly-paths.sh` for the acceptance cases, replacing automatic
symlink-target/intermediate-directory protection and contained-link refusal
expectations. In `tests/unit/attachment.sh`, verify that creating or retargeting
a contained link alone does not block attachment, retaining its already-valid
read-only-child-under-writable-lane case. Extend runtime security fixtures and
affected lifecycle cases, and keep bounded matrix inventories/documentation
synchronized.

Update README precedence and symlink propagation explanations. Replace the
claims that writable lanes cannot nest, that a lane cannot equal or lie beneath
a protected path, and that contradictory writable/protected declarations remain
invalid. Explain most-specific read-only/writable policy, exact-path ties, and
absolute hidden/automatic protection with a writable-child example. Replace
claims of automatic symlink-target/intermediate-directory protection and
contained-link rejection, including project-root targets, with user-managed
destination policy and its integrity limits. Explain silent overlap suppression.

Run `tests/run dev` and affected suites, with permission-sensitive cases under
umasks `0022` and `0002`. Run runtime and matrix gates when their prerequisites
are available; record unavailable coverage explicitly. Full portable coverage
remains a CI requirement.
