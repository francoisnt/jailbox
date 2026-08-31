# 1. Explicit read-only project paths

## Goal

Replace jailbox's built-in protected-path list and additive `READONLY_EXTRA`
setting with one explicit `READONLY_PATHS` configuration setting. Validate every
configured entry before launch. In addition, protect the default project config
when it exists, the selected in-project config, and the exact in-project
Containerfile used for the build.

This change does not redesign container lifecycle, configuration-file creation,
resource ownership, or concurrent-launch behavior.

## Sequence

Order 1.0. Requires nothing earlier and is independent of the command-mode
sequence in plans 2 through 6, which can land before or after it.
`01.1-init-config-plan.md` uses its public setting, and
`07-writable-paths-plan.md` and `08-hidden-paths-plan.md` require the shared
`check_project_mount_path` primitive defined here.

## Configuration

`READONLY_PATHS` is a comma-separated array in jailbox's strict configuration
format:

```conf
READONLY_PATHS=.env,.github/workflows,.git/config,.git/hooks
```

An empty value is valid:

```conf
READONLY_PATHS=
```

No Bash-array syntax is accepted. Paths from an externally selected config are
still interpreted relative to `$PROJECT_DIR`.

Each entry must:

- be a non-empty project-relative path;
- contain no `.` or `..` segment, colon, or trailing slash;
- exist at launch;
- be a regular file or directory;
- have no symlink component below the canonical project root;
- resolve canonically beneath the canonical project root; and
- be unique within `READONLY_PATHS`.

Reject the complete configuration when any entry is invalid. Do not normalize
unsafe input, skip missing entries, or silently remove duplicates.

Symlink checks begin below the canonical project root. The spelling used to
reach the project root itself may contain a symlinked prefix, as commonly occurs
with `/var` and `/private/var` on macOS.

That project-root exception does not extend to a directly selected external
config or Containerfile. Project policy entries are relative to an already
canonical `$PROJECT_DIR`, so a host symlink above that trust root is not
project-controlled input. An external selection is supplied as a complete path
and the strict trusted-input rule checks that complete spelling; on macOS a
caller or test using a `/var` or `$TMPDIR` spelling must pass its physical
`/private/var` path instead. Keep this asymmetry explicit in diagnostics and
portable fixtures.

Implement the common layer in `host/common.sh` with focused, named helpers:

- `validate_project_mount_path_lexical` checks relative spelling, dot segments,
  colons, trailing slashes, and empty entries;
- `check_project_path_no_symlinks` walks components below the canonical project
  root without following a project-controlled component;
- `canonical_project_relative_path` canonicalizes an existing candidate and
  proves containment beneath canonical `$PROJECT_DIR`; and
- `project_path_type` classifies the canonical result as a regular file,
  directory, or special file.

Compose them in `check_project_mount_path`, which verifies lexical shape,
existence, regular-file-or-directory type, absence of symlink components, and
canonical containment, and returns the canonical project-relative spelling.
`READONLY_PATHS`, `WRITABLE_PATHS`, and `HIDDEN_PATHS` must call this common
primitive from their policy-specific checks so their shared safety rules cannot
drift. Their array-level duplicate and overlap rules remain policy-specific.
All three policies accept only regular files and directories. Reject FIFOs,
Unix sockets, character and block devices, and every other special file; no
policy silently follows or mounts a symlink.
Other path-bearing inputs, including `DEV_CONTAINERFILE`, `DEV_BUILD_CONTEXT`,
and `--config`, must reuse those helpers wherever their different semantics
permit; do not force them through one top-level validator when, for example, an
external path is intentionally valid.

## Effective read-only paths

The effective set, in deterministic order, is:

1. every configured `READONLY_PATHS` entry, preserving declared order;
2. `$PROJECT_DIR/jailbox.conf` when it exists, even when `--config PATH` selects
   another file;
3. the selected config when its canonical path is inside the project; and
4. the exact Containerfile used by `podman build` when its canonical path is
   inside the project.

Deduplicate identical destinations. jailbox adds no other implicit paths: `.env`,
Git files, workflow directories, its source tree, and unused Containerfile
candidates remain writable unless configured explicitly.

The official jailbox repository needs no special source-tree protection merely
because it uses jailbox to develop itself. Its source is project content and
follows the same explicit `READONLY_PATHS` policy as every other project. Remove
the current in-project `SCRIPT_DIR` special case with the other built-in paths.
Automatic protection remains limited to project inputs that jailbox identifies
and consumes as part of a launch: the default policy anchor, selected
in-project config, and exact used in-project Containerfile.

An external selected config or Containerfile is not reachable through the
project mount and receives no overlay. Selecting an external config does not
remove the separate default-config overlay. `01.1-init-config-plan.md` owns its
creation and the actionable missing-anchor error. When `DEV_IMAGE` is selected,
no Containerfile is used or added.

The default config, selected config, and Containerfile are host-consumed launch
inputs rather than ordinary project policy. When the default path exists,
require it to be a readable regular file with no symlink component, even when it
is not selected. Reject every selected config or Containerfile whose supplied
path has a symlink leaf or intermediate component, whether the input is inside
or outside the project. Perform these checks before parsing the selected config
or invoking `podman build`. Users selecting an external input through a symlink
must instead supply its real path directly. Canonicalizing first and accepting
only the target is insufficient because it erases the spelling the caller asked
jailbox to consume.

Configured-path validation runs at the start of sandbox launch, before image
builds, network creation, SSH credential generation, volume creation, or
container creation. An existing default config and the selected config are
classified before parsing, and the exact Containerfile is classified after
discovery but before `podman build`.
Commands that do not launch a sandbox retain their current behavior and do not
perform configured-path existence or symlink validation.

Construct one `:Z,ro` bind mount for every effective entry. Recheck every source
immediately before constructing its mount argument. This narrows, but does not
eliminate, the race before Podman resolves the source path; host processes and
an existing writable sandbox can still change project paths during launch.
Lifecycle locking and an explicit-stop requirement are separate work.

jailbox no longer creates `.env` or workflow-directory stubs. A configured path
must already exist. If a path does not exist, it cannot be protected by this
mechanism and code in the sandbox may create it later.

The existing default config, selected in-project config, and used in-project
Containerfile are protected without appearing in `READONLY_PATHS`. Projects
must still list every other path they want protected.

## Implementation

- In `host/public-api.sh`, replace `READONLY_EXTRA` with `READONLY_PATHS` in
  `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`, and default assignment.
- Add `tests/unit/public-api-diff.sh` as focused coverage for
  `scripts/public-api-diff.sh`. Build an isolated temporary Git fixture with a
  baseline `host/public-api.sh`, copy the real diff script into the fixture's
  `scripts/` directory, and run that copy so its `BASH_SOURCE`-derived
  `ROOT_DIR` resolves to the fixture rather than the jailbox checkout. Assert
  unchanged, added, and removed outcomes for configuration and CLI declarations.
  Keep the fixture independent of published tags and network access. Unit
  scripts are discovered automatically, so this places public-API release
  classification in the portable gate and gives later command plans a concrete
  suite to extend.
- In `host/common.sh`, assign parsed array values to `READONLY_PATHS`. Replace
  `validate_readonly_extra` with a lexical `READONLY_PATHS` validator for empty,
  absolute, dot-segment, colon-containing, trailing-slash, and duplicate
  entries. Reject colon because the validated paths are later placed in
  colon-delimited Podman volume arguments; make this part of the shared
  `validate_project_mount_path_lexical` helper used by later path-policy plans.
- In `host/container-runtime.sh`, keep public configured `READONLY_PATHS`
  separate from runtime-owned `EFFECTIVE_READONLY_PATHS`. Its initializer resets
  only the effective array and mount arguments; it must not erase configuration
  already loaded. This is a rename-in-place with an ownership inversion: the
  current runtime-owned `READONLY_PATHS` variable becomes
  `EFFECTIVE_READONLY_PATHS`, while the name `READONLY_PATHS` becomes parsed
  public configuration owned by `host/common.sh`. Remove
  `configure_readonly_paths`, `readonly_paths_contain`, and
  `ensure_readonly_stubs`.
- Add `check_project_mount_path` and its named low-level helpers as the shared
  primitive above. Add a policy-specific `check_readonly_path` wrapper that
  calls it and supplies read-only-policy diagnostics. Use that wrapper both in
  the pre-launch validation pass and the pre-mount recheck so the two passes
  cannot drift. Plans 7 and 8 add `check_writable_path` and `check_hidden_path`
  wrappers around the same common primitive rather than calling the read-only
  wrapper.
- Repurpose the existing `canonical_project_relative_path` in `host/common.sh`
  as the canonical-containment helper named in this plan; do not add a second
  function with the same responsibility. Its callers must perform the new
  lexical and no-symlink checks before canonicalization where required.
- Add a trusted-input classifier for the default config, selected configs, and
  Containerfiles. Before canonicalization, reject a symlink in any component of
  the supplied path. Then distinguish a valid directly external path from an
  in-project path. For an in-project input, require canonical containment and
  return the canonical project-relative path for the effective set.
- Preserve each trusted input's original spelling until classification; do not
  let the current `realpath` in `prepare_config_selection` erase the evidence
  needed to detect a project-controlled symlink. When the default config exists,
  classify it before parsing any selected config, including when `--config PATH`
  selects another file. Then classify the selected config before parsing it. In
  `build_or_select_dev_image`, run it after discovering the exact Containerfile
  and before constructing or executing `BUILD_CMD`. Preserve parsed
  `DEV_CONTAINERFILE` as configuration; discovery must not overwrite it.
  Declare image-owned `SELECTED_DEV_CONTAINERFILE` in `host/dev-image.sh` and
  reset it in `initialize_dev_image_state`. Both discovery branches populate it:
  an existing explicit `DEV_CONTAINERFILE` is classified into it rather than
  returning with no selected state, and implicit discovery classifies the
  winning candidate into it. Selecting `DEV_IMAGE` leaves it empty. Refactor
  selection to return a distinct non-zero missing outcome instead of calling
  `die`, both when an explicit configured path does not exist and when implicit
  discovery finds no candidate. The launch caller converts an explicit miss to
  a path-specific "configured Containerfile does not exist" error and an
  implicit miss to the existing build-oriented "no Containerfile found" error.
  Plan 4's attach-time digest computation handles either miss without pretending
  an image build was requested. Other classifier failures, including symlinks,
  non-regular files, and unreadable files, retain their specific validation
  errors rather than collapsing to `missing`.
  `DEV_IMAGE` short-circuits this entire Containerfile selection and
  classification path: leave `SELECTED_DEV_CONTAINERFILE` empty and do not
  inspect, validate, or report an otherwise configured `DEV_CONTAINERFILE`,
  because no Containerfile is consumed or protected in image-selection mode.
- In `build_or_select_dev_image`, change both existing consumers of the mutated
  config variable to consume the classified image state: construct
  `BUILD_CMD` with `-f "$SELECTED_DEV_CONTAINERFILE"` and render the build
  progress message from `SELECTED_DEV_CONTAINERFILE`. No build or display path
  may read post-discovery `DEV_CONTAINERFILE`; it remains the caller's parsed
  configuration value. Using the classified absolute selected path also makes
  an explicit relative Containerfile independent of the host working directory.
- Finalize `EFFECTIVE_READONLY_PATHS` after image selection from configured
  paths, the classified default-config path when present, the classified
  selected-config path, and the classified Containerfile path.
  Deduplicate destinations directly while preserving the order above. During
  the pre-mount recheck, run `check_readonly_path` for configured entries and
  rerun the trusted-input classifier on each automatic input's original
  spelling; checking only a previously canonicalized result would miss a
  replaced symlink.
- Name the pre-launch configured-policy pass
  `validate_configured_readonly_paths` and the post-image-selection assembly
  step `finalize_effective_readonly_paths`. Plan 3's extracted launch core calls
  these exact functions; defining their ownership here avoids introducing them
  accidentally during the later refactor.
- Keep `READONLY_MOUNTS` as container-runtime state. `build_readonly_mounts`
  resets it and emits a `-v` argument for every effective entry; it no longer
  skips absent paths or prints the old `READONLY_EXTRA` warning.
- In `jailbox`, remove `configure_readonly_paths` from
  `initialize_launch_state` and `ensure_readonly_stubs` from `run_launch`. Add
  configured-path validation at the beginning of `run_launch`, before
  `check_local_port_available` and all launch side effects.
- In `host/validation.sh`, check `EFFECTIVE_READONLY_PATHS`, not only the public
  configured array. With a selected in-project config the effective set is
  non-empty even when `READONLY_PATHS` is empty; an external config with
  `DEV_IMAGE`, no default config, and empty `READONLY_PATHS` can still produce a
  legitimately empty effective set at order 1.0. In that case,
  `check_readonly_mounts` returns successfully without output and does not
  increment `WARNINGS`; remove the current
  "No read-only mounts were available to validate" branch, whose existing
  predicate is that zero entries were checked. Plan 1.1 makes the anchor
  mandatory and owns restoring that zero-checked branch as an internal
  regression signal.
- Update the supported-settings header in `jailbox`, README configuration table,
  examples, recipes, and threat model. Remove claims about built-in protection
  and stub creation.

Do not retain `READONLY_EXTRA` as an alias. The strict parser reports it as an
unknown setting.

Review `scripts/public-api-diff.sh`: replacing `READONLY_EXTRA` with
`READONLY_PATHS` includes a removal, so it is a minor public-API change before
1.0 and would be a major change after 1.0 under the repository's release policy.

## Security documentation

Update the README threat model to state plainly:

- the existing default config, selected in-project config, and used in-project
  Containerfile are protected automatically, and only paths explicitly listed
  in `READONLY_PATHS` receive additional read-only overlays;
- an external selected config does not remove protection from the default
  `jailbox.conf`; after plan 1.1, its absence blocks launch because otherwise the
  sandbox could create policy for a later bare launch;
- the writable project mount can change every other project path, including
  unused Containerfile candidates;
- configured paths must exist before launch;
- read-only overlays do not make their contents secret; and
- validation and the pre-mount recheck do not eliminate filesystem races before
  Podman resolves the bind source.

## Tests

Update `tests/unit/config-parser.sh`, `tests/unit/readonly-paths.sh`,
`tests/unit/runtime-mounts.sh`, and `tests/integration/runtime-security.sh` to
cover:

- empty `READONLY_PATHS` parsing and launch behavior;
- removal and rejection of `READONLY_EXTRA`;
- portable-gate coverage of `scripts/public-api-diff.sh` using an isolated Git
  baseline, including unchanged, added, and removed public configuration and
  CLI declarations;
- preservation of configured order;
- read-only mount construction for files and directories;
- rejection of absolute, empty, dot-segment, colon-containing, trailing-slash,
  duplicate, missing, outside-project, symlinked, and special-file entries;
- rejection of leaf and intermediate-component symlinks;
- acceptance when only the canonical project root's host spelling has a
  symlinked prefix;
- rejection of a directly selected external config or Containerfile whose
  supplied path uses a symlinked host prefix, including the macOS `/var` form,
  with acceptance when the same target is supplied through its physical path;
- identical results from pre-launch validation and the pre-mount recheck;
- absence of the superseded built-in `.env`, Git, workflow, and jailbox-source
  paths when `READONLY_PATHS` is empty;
- absence of `.env` and workflow stub creation;
- automatic protection of the selected in-project config and exact used
  in-project Containerfile, plus an existing default config even under external
  `--config`; direct external inputs receive no overlay and selecting `DEV_IMAGE`
  adds no Containerfile;
- an external config with `DEV_IMAGE`, no default config, and empty
  `READONLY_PATHS` produces no read-only mounts and no validation warning at
  order 1.0;
- rejection of an existing default config that is unreadable, non-regular, or
  reached through a symlink, including when another config is selected;
- rejection of project-reachable config and Containerfile symlinks before the
  host parses or builds them, plus rejection of directly selected external
  config and Containerfile symlinks;
- initialization and reset of `SELECTED_DEV_CONTAINERFILE`, population by both
  explicit and implicit selection, and exclusive use of that classified path by
  the `podman build -f` argument and build progress message;
- path-specific launch failure for a missing explicit `DEV_CONTAINERFILE` and
  the existing discovery guidance for an implicit no-candidate launch;
- successful `DEV_IMAGE` selection without Containerfile discovery or
  validation even when `DEV_CONTAINERFILE` is also configured and names a
  missing, symlinked, unreadable, or non-regular path; no Containerfile enters
  the effective read-only set in this mode;
- enforcement of every effective overlay in a running sandbox.

Run `tests/run portable`. Also run `tests/run runtime` because this changes
project mounts and the documented security contract.

## Non-goals

- Automatically protecting launch inputs other than an existing default config,
  selected config, and exact used Containerfile.
- Creating a default `jailbox.conf`.
- Adding `jailbox stop` or changing `--replace` behavior.
- Changing cleanup or Podman resource-ownership rules.
- Adding lifecycle locks or closing filesystem race windows.
- Writable project lanes.
