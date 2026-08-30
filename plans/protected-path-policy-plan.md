# Explicit protected project paths

## Goal

Make the project's read-only policy explicit in configuration. Every declared
path is present and validated before launch, and every effective path is mounted
read-only inside the sandbox.

## Configuration

`READONLY_PATHS` is a comma-separated array in the strict config data format:

```conf
READONLY_PATHS=.env,.github/workflows,.git/config,.git/hooks
```

An empty value is valid. No Bash-array syntax is accepted.

Each entry must:

- be a non-empty project-relative path;
- contain no `.` or `..` segment and no trailing slash;
- exist before launch;
- contain no symlink component;
- resolve canonically beneath the canonical project root immediately before
  its mount is constructed; and
- be mounted read-only.

Reject duplicate entries. Missing, outside, symlinked, and otherwise invalid
entries fail before any container, network, volume, or credential is created.
Do not silently normalize unsafe input.

## Effective protected paths

Two rules define the effective set.

**Host-trusted launch inputs that resolve inside the project.** jailbox reads or
executes these on the next invocation, so code inside the sandbox must not be
able to author them. A config file is launch policy the host trusts; a
Containerfile is a build input the next launch executes through `podman build`.

**Paths the project declares.** Every configured `READONLY_PATHS` entry.

The first rule currently resolves to three files: the default
`$PROJECT_DIR/jailbox.conf` policy anchor, the selected config file when it
resolves inside the project, and the exact Containerfile used to build the
development image when it resolves inside the project. A launch input added
later is covered by the rule without extending this list.

The default config is always present before a sandbox launch and is always
protected, including when `--config PATH` selects a different file. Finalize the
effective set after `build_or_select_dev_image` identifies the exact
Containerfile, then construct the overlays. Deduplicate identical mount
destinations while preserving deterministic order; on bare launch the anchor and
the selected config are the same file and collapse to one entry.

An external selected config or Containerfile is not reachable through the
project mount and receives no project overlay. When `DEV_IMAGE` is selected, no
Containerfile is used and none is added automatically.

## Default configuration policy anchor

Every command that creates a sandbox ensures that
`$PROJECT_DIR/jailbox.conf` exists before configuration selection and loading.
Today that is bare `jailbox`; `jailbox up` joins that set when command mode is
implemented. Create this complete file when the path is absent:

```conf
# Project paths that jailbox must mount read-only.
READONLY_PATHS=
```

Write the complete contents to a temporary regular file in the project
directory and publish it atomically with no-replace semantics. Never overwrite
an existing path, never expose a partial file, remove the temporary file on
every failure path, and load the complete file published by another process if
it wins a creation race.

Whether newly created or already present, the default path must be a readable
regular file and must not be a symlink. Reject a directory, device, FIFO,
socket, unreadable file, or symlink before loading any launch configuration.
This validation also applies when `--config PATH` selects another file: the
external or alternate config remains the only file parsed, but the default
policy anchor is still created, validated, and mounted read-only.

Commands that do not create a sandbox do not create the default config. Today
that includes `stop`, `doctor`, `ssh-config`, `--clean`, and `--uninstall`;
future `exec` and `shell` follow the same rule.

Use a small sandbox-creating-command predicate only at top-level dispatch to
decide whether to create the anchor. It examines the post-`--config` positional
command directly: bare launch is the only match in this implementation, and
command mode later adds `up`. Do not introduce shared command state.

## Explicit stop before relaunch

A running sandbox has the project mounted writable and can race path validation,
image builds, and mount construction. Launch therefore never stops or replaces a
running sandbox implicitly. If the project development container is running,
bare `jailbox` fails before path validation or image work and directs the user to
run `jailbox stop` first.

This intentionally makes relaunch a two-command operation. A failed build after
`jailbox stop` leaves no sandbox container running; preserving a writable
fallback during the build would reintroduce the race this boundary removes.

Add `jailbox stop` in this implementation. Containers are ephemeral runtime
objects: `stop` stops and removes the project development and proxy containers
while preserving networks, images, the home volume, and SSH state. It is
idempotent and succeeds when both containers are absent. Before mutating
anything, inspect every present target and require its `jailbox.project` label
to equal canonical `$PROJECT_DIR`; a missing or mismatched ownership label fails
without stopping or removing either container. It never creates the default
config and does not run `READONLY_PATHS` semantic validation.

Launch requires both `$CONTAINER_NAME` and `$PROXY_NAME` to be absent. Inspect
every existing name before path validation or image work. For a container whose
`jailbox.project` label matches canonical `$PROJECT_DIR`, fail with the
`jailbox stop` instruction. For an unlabeled or mismatched container, report a
name collision and tell the user to inspect and remove it explicitly with
Podman; do not direct them to a `stop` command that will correctly refuse it.

Remove `--replace` from both development- and proxy-container `podman run`
commands. Concurrent launches can no longer silently replace each other's
containers, but they are not safe overall: both may mutate shared SSH,
network, and other lifecycle state before one loses the container-name race.
Concurrent lifecycle commands remain unsupported and locking is a separate
change.

After the absence check, `check_local_port_available` always probes the derived
port. Remove its existing container-exists exception; no valid launch-time
container can hold the port.

Apply the same ownership requirement to `clean_jailbox`
(`host/container-runtime.sh`), which today stops and removes both containers,
the home volume, and the project networks purely by derived name. Every one of
those resources already carries a `jailbox.project` label, so verify each before
removing it. `--clean` skips and reports an unlabeled or mismatched resource
instead of failing, because it is terminal cleanup: refusing outright would
leave the user with no way to remove what jailbox does own. `stop` fails
instead, because it is a precondition for launch and the user must resolve the
mismatch before relaunching.

Do not add a flag that relaunches over a running sandbox. The two-command flow is
the boundary this section exists to establish, and an opt-out would reintroduce
the race for the most common operation.

## Removing the built-in protected set

The effective set above is complete. jailbox no longer carries an implicit list
of protected project paths, and no longer materializes absent paths so that it
has something to overlay. Protection is declared, not inferred.

Remove:

- `configure_readonly_paths` (`host/container-runtime.sh`) in its entirety and
  its call from `initialize_launch_state` (`jailbox`). Its built-in seed,
  in-project `SCRIPT_DIR` handling, premature `DEV_CONTAINERFILE` resolution,
  `READONLY_EXTRA` merge, and selected-config handling are all superseded by the
  explicitly ordered sources in `finalize_effective_readonly_paths`;
- `readonly_paths_contain` (`host/container-runtime.sh`). Finalization still
  deduplicates identical destinations, but owns that operation directly rather
  than retaining a helper coupled to the superseded array;
- `ensure_readonly_stubs` (`host/container-runtime.sh`) and its call in
  `run_launch` (`jailbox`), including the `.env` and workflow-directory stub
  behavior it implements;
- the absent-path launch warning in `build_readonly_mounts`
  (`host/container-runtime.sh`), which hard validation failure replaces;
- the unreachable "Replacing existing jailbox container" branch in
  `start_jailbox_container` (`host/container-runtime.sh`) and "Replacing
  existing proxy container" branch in `configure_proxy_network`
  (`host/network.sh`); launch now requires both names to be absent;
- `test_stubs` and `test_stubs_from_empty_project` in
  `tests/unit/readonly-paths.sh`, and every assertion in that file, in
  `tests/unit/runtime-mounts.sh`, and in `tests/integration/runtime-security.sh`
  that expects a built-in default to be protected without being configured; and
- the README "Protect extra project files" recipe and the threat-model bullets
  describing the built-in list and the stub behavior; replace the recipe with
  an explicit `READONLY_PATHS` example rather than dropping the use case.

`check_readonly_mounts` (`host/validation.sh`) iterates the effective array and
must follow the rename below. Because every sandbox launch protects the default
config, a successfully finalized effective set is never empty; retain the
warning as an internal regression signal.

Because a configured path must already exist and jailbox never creates one, a
protected path that does not exist yet cannot be protected at all — a `.env` the
project has not written, or `.git/config.lock`, which exists only during a Git
config write. Until such a path exists, code in the sandbox can create it. The
threat model must state this plainly.

## Public API and implementation

- Add `READONLY_PATHS` to `CONFIG_ARRAY_KEYS`, defaults, parser assignment,
  help, documentation, and generated public-API expectations.
- Remove `READONLY_EXTRA` from `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`,
  `set_config_array`, README examples, tests, and generated public-API
  expectations. Replace `READONLY_EXTRA` with `READONLY_PATHS` in the supported
  settings header at the top of `jailbox`; `usage()` lists CLI flags rather than
  config keys and needs no config-key edit. Remove `validate_readonly_extra` and
  its call from `validate_config` (`host/common.sh`); do not retain
  `READONLY_EXTRA` as an alias, so the strict parser reports it as an unknown
  key.
- Replace internal names derived from the old API with names that distinguish
  configured paths from the finalized effective path set. Keep
  `READONLY_PATHS` as the public configured array and rename the current
  host/container-runtime-owned effective array to `EFFECTIVE_READONLY_PATHS`.
  `host/common.sh` validates configured entries; `host/container-runtime.sh`
  owns finalization, deduplication, mount construction, and runtime validation
  inputs.
- Update `initialize_container_runtime_state` (`host/container-runtime.sh`) to
  reset `EFFECTIVE_READONLY_PATHS`, not the public configured `READONLY_PATHS`.
  The initializer must never erase values loaded from configuration.
- Add `ensure_default_project_config` in `host/common.sh`. Call it for a
  sandbox-creating command only after project resource names are initialized and
  `require_sandbox_absent` succeeds, and before `prepare_config_selection`. A
  newly created default is therefore immediately selected and parsed by bare
  `jailbox`, but no running sandbox can write it. The helper also runs before
  selection when `--config PATH` is present, without changing which config is
  selected.
- Add a pure `command_creates_sandbox` predicate that accepts the validated
  post-`--config` positional command. In `main`, call
  `ensure_default_project_config` when that predicate succeeds, before
  `prepare_config_selection`. Bare launch is its only match in this
  implementation; command mode later adds `up`.
- Add `stop` to `CLI_FLAGS_WITHOUT_VALUES` and `CLI_HELP` in
  `host/public-api.sh`, and update parsing, dispatch, README command and
  lifecycle documentation, and generated public-API expectations. The
  `Options:` block in `usage` (`host/common.sh`) is generated from those arrays,
  but the literal `Usage:` synopsis above it must be edited by hand to list
  `stop`. The command requires Podman only and dispatches without creating the
  policy anchor or enforcing protected-path semantics.
- Add `require_sandbox_absent` and `stop_jailbox` to
  `host/container-runtime.sh`. `require_sandbox_absent` is a read-only check used
  by top-level launch dispatch before anchor creation or config loading; it
  distinguishes an owned leftover, which names `jailbox stop`, from an unlabeled
  or mismatched collision, which names manual Podman inspection and removal.
  `stop_jailbox` first validates the ownership label of every present target,
  then stops and removes both containers without deleting persistent resources.
- Move `initialize_project_names` out of `initialize_launch_state` and call it
  once after argument parsing, before command-specific dispatch. Project and
  resource identity depends only on canonical `$PROJECT_DIR`, not on loaded
  configuration. The remaining module initializers stay in
  `initialize_launch_state` after configuration loading.
- In `host_preflight` (`host/preflight.sh`), add `stop` to the existing
  Podman-only early-return branch used by `--clean`, before SSH, `realpath`, and
  editor checks.
- Add a scoped early branch in `main` for `stop` only: after argument parsing and
  project-name initialization, call `host_preflight stop`, dispatch
  `stop_jailbox`, and return before `prepare_config_selection` or
  `load_project_config`. Leave the existing post-config `host_preflight "$@"`
  call in place for every other command; do not move it globally ahead of config
  loading, because bare launch needs parsed `EDITOR` before editor preflight.
  Ignore a supplied `--config PATH` for `stop`: stopping project-scoped
  ephemeral containers does not depend on configuration, and malformed or
  missing policy must not block restoration of the launch precondition.
- Define one `check_configured_path` primitive that fully validates a single
  entry: lexical shape, existence, absence of any symlink component, and
  canonical containment beneath the canonical project root. It is the only
  definition of a valid entry, and it is the one canonical containment helper
  for all project-relative mount inputs. Neither caller below re-enumerates its
  checks.
- Run that primitive over the entries twice, for two different reasons.
  `validate_configured_readonly_paths` maps it at the top of `run_launch`,
  before any image build, network, credential, or volume work, so an invalid
  entry fails without leaving side effects behind; this pass also rejects
  duplicates, which are a property of the set rather than of an entry.
  `finalize_effective_readonly_paths` runs after development-image selection and
  re-invokes the primitive for each entry immediately before emitting that
  entry's mount, so a path replaced during the launch cannot become a mount
  source.
- Separate configured paths from the finalized effective mount list so image
  discovery can add only the Containerfile actually used.
- All `READONLY_PATHS` semantic checks are launch-only and run from `run_launch`
  rather than from general configuration loading, so a missing, replaced, or
  otherwise invalid configured project path cannot prevent `doctor`,
  `ssh-config`, `--clean`, or `--uninstall` from operating. Unknown keys and
  ordinary config grammar errors retain their existing behavior for every
  command.
- Build read-only overlays only after all validation succeeds. Preserve the
  current `:Z,ro` bind-mount options in this change; the separate SELinux mount
  label recommendation owns any change to relabeling behavior.
- Keep configuration a strict data format; never evaluate path values as shell
  code or use them as unvalidated associative-array subscripts.

The launch sequence for this change is:

1. parse the command and leading `--config` option;
2. initialize project identity and derived resource names;
3. for `stop`, run Podman-only preflight and dispatch without configuration
   loading;
4. for a sandbox-creating command, require both development and proxy container
   names to be absent;
5. ensure and validate the default project config;
6. select, load, and generally validate the requested config;
7. initialize the remaining module state;
8. validate configured `READONLY_PATHS` and check the local port;
9. select or build the development image and build the wrapper image;
10. configure runtime mounts, networks, and credentials;
11. finalize `EFFECTIVE_READONLY_PATHS`, rechecking each entry as its mount
   argument is built;
12. create the home volume and start the container.

No image, network, credential, volume, or development container work begins
before steps 4 and 8 succeed.

The pre-mount recheck narrows the tampering window but does not close it.
`build_readonly_mounts` assembles argument strings, and Podman resolves each
source path when `start_jailbox_container` runs. After step 4 no sandbox holds a
writable project mount, so the residual window covers only ordinary host
processes. State this in the threat model rather than implying the race is
eliminated.

Review the generated public-API diff because removing `READONLY_EXTRA` and
adding `READONLY_PATHS` changes the configuration surface. With an empty
`READONLY_PATHS`, only the default policy anchor, a different selected
in-project config, and the exact in-project Containerfile actually used are
protected automatically.

## Documentation

Update the README examples and threat model to state that project policy paths
are protected through `READONLY_PATHS`, and that the built-in protected set and
its stubs are gone. Replace the existing protected-files recipe with a
`READONLY_PATHS` example. Document the automatic default policy anchor,
selected-config, and Containerfile entries and the requirement that every
configured path already exist.

Document the explicit `jailbox stop` prerequisite for relaunch, that it removes
only ephemeral containers, the persistent resources it preserves, and that a
failed subsequent launch leaves no sandbox container running. Document that
unowned name collisions require manual Podman resolution and that concurrent
lifecycle commands are unsupported because they can corrupt shared state even
though they no longer silently replace containers.

Document that `--clean` acts only on resources this project owns and reports
anything it skips, and that no flag relaunches over a running sandbox.

The threat model must remain explicit that the writable project mount permits
changes to any path outside the effective set, that read-only overlays do not
make other project content secret, that a path which does not exist at launch is
not protected and can be created from inside the sandbox, and that the pre-mount
recheck narrows rather than closes the window before Podman resolves each mount
source.

## Tests

- Empty `READONLY_PATHS` loads successfully; runtime validation checks the
  automatically protected default config and produces no warning.
- `READONLY_EXTRA` is rejected as an unknown key, is absent from help and
  documentation, and appears as removed in the generated public-API diff.
- Apart from the default policy anchor, no path is protected unless it is
  configured or is the selected config or Containerfile; a project with an
  empty `READONLY_PATHS` receives no overlay for `.env`, `.git/config`,
  `.git/hooks`, or the workflow directories.
- No stub file or directory is created for any absent path, and launch leaves
  the project tree otherwise unmodified apart from creating the default config
  when needed.
- Bare launch atomically creates a missing default config with the complete
  template before selecting and loading it. Concurrent creators preserve one
  complete winning file without overwrite, partial content, or leftover
  temporary files.
- With either container present, launch fails before creating, validating, or
  loading the default config. A running sandbox therefore cannot gain a window
  to author a newly trusted policy anchor during a failed relaunch.
- Launch with an external `--config PATH` still creates and protects the default
  project config but parses only the selected external file.
- An existing default config is never overwritten. An existing default path
  that is a symlink, directory, device, FIFO, socket, or unreadable file fails
  before launch side effects.
- `stop`, `doctor`, `ssh-config`, `--clean`, and `--uninstall` never create the
  default config.
- With a config whose `READONLY_PATHS` entry is missing or has become a symlink,
  bare launch fails before side effects, while `doctor`, `ssh-config`, `--clean`,
  and `--uninstall` remain available and do not create the default config.
- The pure command predicate classifies bare launch as sandbox-creating and
  `stop`, `doctor`, `ssh-config`, `--clean`, and `--uninstall` as non-creating.
- Launch reports `jailbox stop` for an owned development or proxy container, but
  reports an unlabeled or mismatched name collision with manual Podman
  inspection/removal guidance; neither case mutates the existing container.
- `stop` verifies all present development and proxy targets before mutation,
  refuses a missing or mismatched ownership label without partially removing
  resources, and succeeds when both targets are absent.
- `stop` removes owned development and proxy container objects, leaves networks,
  images, the home volume, and SSH state in place, and creates no default config.
- `stop` succeeds with a missing, unreadable, or malformed default or selected
  config, including when `--config PATH` names a missing file, because it does
  not select or load configuration.
- `stop` requires Podman but not SSH, `ssh-keygen`, `realpath`, or an editor; all
  other commands retain their existing preflight placement and requirements.
- Development and proxy container runs do not use `--replace`, and their dead
  replacement notices are removed. Concurrent launches do not silently replace
  one another, but remain unsupported and may leave shared SSH or lifecycle
  state inconsistent.
- `--clean` removes only resources whose `jailbox.project` label matches the
  project, and reports and skips an unlabeled or mismatched container, volume,
  or network instead of failing.
- `stop` appears in the literal `Usage:` synopsis, in the generated `Options:`
  block, and as an addition in the generated public-API diff.
- A failed development-image build after `stop` leaves no sandbox container
  running.
- A foreign listener holding the derived port produces the clear port-conflict
  error before image work.
- Invalid entries are rejected identically by the pre-build pass and by the
  pre-mount recheck, since both call the same primitive.
- Multiple entries preserve order and receive read-only mounts.
- Absolute, traversing, dot-segment, trailing-slash, duplicate, missing, and
  symlinked entries are rejected.
- Leaf and intermediate-component symlinks are rejected. A symlink to a host
  path outside the project can never become a mount source.
- A configured path replaced with a symlink after the pre-build pass is rejected
  by the pre-mount recheck.
- Configured file and directory paths are supported. Nested configured paths
  preserve deterministic order.
- Paths from an external selected config still resolve relative to the project
  root.
- The selected in-project config is protected and an external config is not
  added to the project overlays.
- Only the exact in-project Containerfile used for the build is protected
  automatically.
- Selecting `DEV_IMAGE` adds no automatic Containerfile entry.
- Every effective entry is read-only in a running sandbox.

Update `tests/unit/config-parser.sh`, `tests/unit/readonly-paths.sh`,
`tests/unit/runtime-mounts.sh`, and `tests/integration/runtime-security.sh`.
Keep parser and path-lifecycle cases at the unit layer; use the runtime suite to
prove the emitted overlays, explicit-stop lifecycle, and the absence of
project-tree mutations other than the default config.

Run `tests/run portable` and, because this changes project mounts, container
lifecycle, and the security contract, `tests/run runtime` wherever Podman is
available.

## Non-goals

- Writable project lanes; those are defined in `writable-paths-plan.md`.
- The config digest that gates attaching to a running sandbox;
  `headless-mode-plan.md` owns it.
- Hiding project content from reads.
- Creating absent project paths other than the default `jailbox.conf` policy
  anchor.
- Changing when `setup_ssh_keys` regenerates credentials, or making a partially
  failed launch recoverable.
