# Frontend verification evidence

The frontend uses the public CLI as a consumer. This map identifies existing
coverage and the integration cases added during its closing verification;
it does not introduce a fifth gate. A listed test is coverage, not a claim that
a platform or complete gate has passed. Run results belong in the handoff.

## Portable contracts

| Contract | Regression evidence |
|---|---|
| Strict file grammar, controls/NUL, anchors, deduplication, inherited-policy removal, unrelated environment preservation, value-free notices | `unit/frontend-file-policy.sh`, value-free names/order in `unit/attachment-digest-context.sh`; public launch/headless/file-validation NUL refusals in `unit/frontend-cli.sh` |
| Real public file validation without engine/SSH/editor prerequisites; file-only keys and selected-file failures | `unit/frontend-cli.sh`, `unit/validate-command.sh`; failed child validation with plausible stdout in `unit/frontend-file-policy.sh` |
| Identical up/connection-info environments, command order, current validation after successful up, failure status and prevention of editor launch | `unit/frontend-editor.sh` with `fixtures/editor-client/core.sh` |
| Both editors' exact bootstrap sets reach the digest gate and rendered filter; machine/frontend/headless equivalent reuse; actual policy changes refuse without mutation | `unit/frontend-cli.sh` with the existing convergence engine/transport fixture; `unit/network.sh`, `unit/config-digest.sh` retain core set semantics |
| Default/selected anchors reach digest and read-only mount arguments; external selection adds no anchor; prelisted anchors allow equivalent selection | `unit/frontend-cli.sh`; actual mount immutability remains in runtime `e2e/headless.sh` |
| File-only editor selection, automatic Codium/Code fallback, ignored inherited editor variables, complete preflight refusals, inventory failures, versions differing from pins | `unit/frontend-editor.sh` |
| Required connection values/order, NUL framing, duplicates, truncation, malformed input, opaque trailing fields | `unit/frontend-connection.sh`; launch refusal after malformed records in `unit/frontend-editor.sh` |
| Independent JSON round trips for spaces, quotes, backslashes and Unicode; optional proxy; no terminal proxy block | `unit/frontend-settings.sh`, `lib/editor/check-settings.py`, `unit/frontend-editor.sh` |
| Safe settings preparation/publication/cleanup; caller traps and settings; prior data preserved; no editor after publication failure | `unit/frontend-settings.sh`, `lib/file-publication.sh`, `unit/frontend-editor.sh`; fixtures cover both umasks |
| Profile relocation and empty/unset fallback; invalid paths refuse before core calls | `unit/frontend-editor.sh` |
| Init suggestions, stable ordering, one live assignment, applying multiple suggestions, no-overwrite and safe publication | `unit/frontend-init.sh`; no runtime prerequisites in `unit/init-config.sh`; running/stopped/network/home inventories preserved in `unit/frontend-cli.sh` |
| Declaration-driven dispatch and config-selection restrictions; machine commands have no editor/file dependency | `unit/cli-dispatch.sh`, `unit/public-api.sh`, `unit/validate-command.sh`, `unit/exec.sh`, `unit/shell.sh` |
| Private functions/globals/state paths and engine access forbidden across the boundary | `unit/frontend-boundary.sh`, `scripts/check-frontend-boundary.py` |
| Migrated runtime layout, installer paths, release packaging, generated references, discovery-based lint/syntax | Existing portable gate, `unit/release.sh`, `unit/runtime-install.sh`, `unit/embedded-programs.sh`, `unit/lint-discovery.sh`, `portable/smoke.sh` |
| Reopen/resume requires fresh task proof; frontend failure prevents readiness/task checks; switch launches do not seed using stale machine policy | `unit/editor-smoke-setup.sh`, `unit/editor-session.sh` |
| Human SSH instructions quote the identity-derived path even under symlinked temporary roots | `unit/ssh-instructions.sh`; fixture uses physical paths like the CLI |

## Real runtime and lifecycle evidence

`e2e/headless.sh` retains core assertions for SSH, mounts, proxy enforcement,
resource reuse and cleanup. A copy of the generated SSH configuration with
client `SetEnv` removed checks server delivery of all six proxy variables;
`unit/ssh-generation.sh` checks refusal of missing or inconsistent container
proxy input, and `unit/ssh-session.sh` checks startup validation and failure
propagation. The real editor task remains the proof that
these variables reach editor-launched tools.

The filtered bare launch explicitly selects Codium
and `EGRESS_ALLOW=example.com`. `lib/frontend-attachment.sh` independently supplies
that file's complete machine policy, including both config anchors and Codium
hosts. It checks successful connection-info, literal exec argv and binary stdin,
and the existing interactive/login/resize/signal shell harness with local TTYs.
Changed policy refuses exec and shell, leaves container inspection unchanged,
and cannot execute the marker command.

The lifecycle matrix continues to own the full resource-state and interruption
matrix, attachment refusals and mutation observations. Frontend commands are
not added to its lifecycle membership. Core identity and authorized-key checks
remain in the wrapper/security/attachment tests; they are not editor assertions.

## Real editor evidence

`e2e/editor-smoke.sh` and `lib/editor/workflows.sh` use the selected pinned editor
on its existing supported image stages. The fixture writes file `EDITOR`.
The gate observes actual remote extension-host attachment, editor task execution,
workspace writes, effective settings through the editor configuration API, and
proxy inheritance inside `editor-validate.sh`. Proof is checked after the editor
task completes; no direct SSH probe can supply the proof. Tasks run on folder
open and through the proof extension's acknowledged task API.

The filtered stage occupies the first subnet candidate as fixture setup. The
settings assertion consumes public connection-info and checks that the editor
uses the reported fallback endpoint. It does not retest routing or enforcement.
Unfiltered stages require absence of the editor HTTP proxy setting. Reopen and
stopped resume go through the public frontend and require fresh task results.

Filtered headless, editor and config-selection switches refuse when policy
changes. After explicit stop/relaunch with all bootstrap hosts and anchors
prelisted, those switches succeed, finishing with a fresh real-editor task.
CI installs one pinned editor per job: the alternate editor is a recording
client for the selection/composition switch, while the selected real editor
proves attachment before and after it. Both pinned clients are exercised by
their respective jobs; this is not a claim that both GUI binaries ran in one job.

## Closing consumer coverage audit

The existing frontend is the consumer under test. Public version and schema
commands are verified directly; an external orchestrator's version-range policy
is not implemented by jailbox and needs no duplicate consumer fixture here.

| Boundary | Existing evidence and focused integration coverage |
|---|---|
| Version framing, invalid stamps, source and installed version identity | `unit/version.sh`, `portable/smoke.sh` |
| Schema framing, new declarations, invalid declarations and dependency isolation | `unit/machine-inventory.sh`, `unit/public-api.sh` |
| File-to-environment composition, identical up/connection-info inputs, command order and failed producers with plausible stdout | `unit/frontend-file-policy.sh`, `unit/frontend-editor.sh`, `unit/frontend-cli.sh` |
| Required connection framing and semantics, missing/duplicate/truncated records, opaque future values | `unit/frontend-connection.sh`; `unit/frontend-editor.sh` proves a future field preserves launch arguments/settings and duplicate or invalid required values prevent launch and settings publication |
| Real public CLI composition, filtered exec/shell attachment and changed-policy refusal | `e2e/headless.sh`, `lib/frontend-attachment.sh` |
| Real editor attachment, settings, reopen and policy switching | `e2e/editor-smoke.sh` |

## Release verification

Release acceptance requires all four complete gates against the final tree,
including the separate VS Code and VSCodium editor jobs. Runtime and matrix
require Linux and Podman; editor also needs its selected editor and a display
or Xvfb. Portable simulations cannot establish these results. Run outcomes,
revision identity, environment limitations, and local evidence locations belong
in the handoff, not this coverage inventory.
