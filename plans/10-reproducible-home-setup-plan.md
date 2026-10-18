# 10. Reproducible home setup

## Intent

Let developers recreate their sandbox home from a script: dotfiles, user tools,
settings, and optional credentials. A configured setup script makes new homes
ephemeral by default, while an explicit retention setting always wins. Keep
system packages in the Containerfile. Implement before
`11.1-go-frontend-plan.md`; that migration must preserve this behavior and its
tests. This plan is independently complete and does not depend on VM work.

### Configuration and execution

- Add `HOME_SETUP_SCRIPT`, an optional project-relative executable script path,
  to project and machine configuration. Machine callers use the corresponding
  `JAILBOX_CONFIG_HOME_SETUP_SCRIPT` spelling. Validate it before mutation,
  reject symlink traversal and escapes from the project, and automatically
  protect the selected script read-only. Conflicting hidden-path policy fails
  explicitly. Execute the selected script through its shebang, without shell
  evaluation of its configured path.
- Run setup only for a newly created home, after SSH and sandbox readiness
  checks pass and before launch succeeds or the editor opens. Run as the
  managed sandbox user, with the normal home, project working directory, and
  effective network policy. Both editor and headless launches use this same
  core-owned behavior; direct machine `up` also supports it.
- Never run setup on an existing home, including a legacy home, simply because
  a script was added or changed. Reusing or resuming a sandbox does not rerun
  it. Existing homes without setup records remain usable under existing
  compatibility and retention rules.
- When `EPHEMERAL_HOME` is omitted, resolve it to `true` if a setup script is
  selected and `false` otherwise. Explicit `true` or `false` wins. Resolve this
  consistently for file and machine callers before digest calculation; an
  explicit value and the same inferred value have identical effective policy.
  Empty or invalid explicit values retain strict validation.
- Preserve recorded retention for existing homes. Adding a setup script must
  not relabel a persistent home or make its contents disposable. Explain any
  incompatible retention request and the existing recovery choices. Ephemeral
  homes are removed on stop, not on every launch; rebuilding one is an explicit
  user action.

### Optional host input

Add `SETUP_INPUT_SCRIPT` in user-owned host configuration. The selected
executable may live in the repository and be committed as a team convention;
its location does not replace the user's explicit selection. Reject unsafe
ownership, group/other write permissions, and symlink redirection for the
configuration, provider, and relevant containing directories. Project
configuration, including a custom `--config` file, cannot select or override
this host executable.

The frontend supplies the trusted selection through the separate host control
`JAILBOX_SETUP_INPUT_SCRIPT`; direct machine callers may explicitly set that
control themselves. It is not a project-policy key. Frontend launches use the
host configuration selection rather than an inherited override. Declare these
surfaces centrally and document their distinct trust boundaries.

Run the provider only when home setup will run, as the invoking host user,
with no arguments and the project root as its working directory. The team is
responsible for the script's safe use of project-local inputs and tools. Do not
source it or evaluate a command string. It may retrieve secrets from any manager or
produce ordinary developer settings. The provider and consumer own their data
format: jailbox neither parses nor validates the payload.

Require successful provider completion before executing the sandbox script,
then deliver its exact stdout bytes through authenticated SSH as the script's
stdin. Preserve binary bytes and trailing newlines. No provider means empty
stdin; successful empty output is valid. Provider failure is a launch failure,
never permission to run setup with partial or empty substituted input.

Treat all payload bytes as sensitive: no logging, command arguments, persistent
mounts, container-wide environment injection, or retained payload files. Any
temporary buffering must be private, outside the checkout, and removed on
success, failure, and handled interruption. Forward script diagnostics without
claiming to redact arbitrary user output; document that both scripts must avoid
printing secrets and that sandbox tools may persist credentials in the home.
Do not pass secret-manager session credentials into the sandbox implicitly.

### Completion and failure

Core owns setup state tied to the home generation, stored outside the project
and sandbox-controlled home. Record pending setup before executing user code;
publish completion only after setup succeeds. Lost or inconsistent required
records must not become permission to repeat setup or claim success.

Provider failure, setup failure, or interruption fails launch and prevents
editor attachment. Preserve the original error through cleanup. Apply existing
rollback and recorded-retention rules; never delete a retained persistent home
to hide a failed setup. A surviving pending or failed home refuses normal
launch/attachment with clear recovery guidance. No automatic retry over partial
contents: users recreate an ephemeral home through stop/launch, or explicitly
recover/delete a persistent home before starting again. Status and recovery
commands remain available without valid setup inputs and never run scripts.

Changing the script affects future initialization, not the contents of an
already initialized home. Include the script's content identity in launch
compatibility so changed launch inputs receive the existing stop/relaunch
guidance; a retained completed home still does not rerun setup. Provider paths
and payloads are not compatibility inputs: refreshing host input alone must
not invalidate a running sandbox or publish secret-derived hashes.

No every-launch hook, automatic refresh, periodic rebuilding, provider-specific
integration, or new concurrency guarantee is included. Callers continue to
serialize lifecycle operations per project.

### Acceptance

Cover the default/explicit retention combinations for file and machine callers;
new persistent and ephemeral homes; reuse, restart, and recreation; legacy
homes; changed scripts; provider absence and failure; exact binary input;
setup failure and interruption; completion publication and recovery. Prove
that project policy cannot select host code, scripts are protected, and input
bytes do not appear in jailbox-generated logs or resource metadata. Exercise
permission-sensitive checks under both `0022` and `0002`.

Use `tests/run dev` and affected suites during implementation. Acceptance uses
the existing portable, runtime, matrix, and editor gates, including both editors.
Runtime verifies actual setup under sandbox restrictions; matrix verifies home
generation, failure, and retention behavior; editor verifies setup precedes
attachment and failure prevents it. Preserve checkout and installed coverage.

## Implementation detail

Keep configuration parsing and trusted host selection in the frontend, and
home lifecycle, initialization records, readiness, and execution orchestration
in core. Frontend calls remain public CLI child processes; it must not inspect
Podman or private core records to decide whether setup is needed. Reuse the
existing SSH execution transport while keeping input stdin separate from
script transfer. Do not add a general host-hook framework.

Extend declarations in `src/public-api.sh` and validate all consuming mappings,
schema output, generated API data, and release-version selection. Migrate the
unconditional retention default in configuration loading to preserve omission
until effective policy is resolved. Update `src/host/frontend/jailbox.conf.template`
to document setup and leave `EPHEMERAL_HOME` commented rather than explicitly
false; preserve existing user configuration without rewriting it.

Update initialization/template tests, lifecycle contracts and fault scenarios,
packaging coverage, and the development, automation, security, and architecture
guides. Provide a small example pair of compatible scripts using ordinary
settings, plus explain secret delivery, retained credentials, destructive home
recreation, and script-author responsibility for reproducibility. Keep the
README introduction short. Archive this plan when implementation is complete.
