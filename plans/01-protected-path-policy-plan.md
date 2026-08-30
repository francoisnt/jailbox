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
`07-writable-paths-plan.md` requires the `check_readonly_path` primitive defined
here.

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
- contain no `.` or `..` segment and have no trailing slash;
- exist at launch;
- have no symlink component below the canonical project root;
- resolve canonically beneath the canonical project root; and
- be unique within `READONLY_PATHS`.

Reject the complete configuration when any entry is invalid. Do not normalize
unsafe input, skip missing entries, or silently remove duplicates.

Symlink checks begin below the canonical project root. The spelling used to
reach the project root itself may contain a symlinked prefix, as commonly occurs
with `/var` and `/private/var` on macOS.

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

An external selected config or Containerfile is not reachable through the
project mount and receives no overlay. Selecting an external config does not
remove the separate default-config overlay. `01.1-init-config-plan.md` owns its
creation and the actionable missing-anchor error. When `DEV_IMAGE` is selected,
no Containerfile is used or added.

The default config, selected config, and Containerfile are host-consumed launch
inputs rather than ordinary project policy. When the default path exists,
require it to be a readable regular file with no symlink component, even when it
is not selected. Reject a selected config or Containerfile when its
project-reachable spelling has a symlink leaf or intermediate component,
including a spelling that escapes the project through a symlink. Perform these
checks before parsing the selected config or invoking `podman build`. A directly
selected external input remains valid. Canonicalizing and protecting only a
symlink target is insufficient because the writable project mount would leave
the project-visible name redirectable.

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
  `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`, default assignment, and generated
  public-API expectations.
- In `host/common.sh`, assign parsed array values to `READONLY_PATHS`. Replace
  `validate_readonly_extra` with a lexical `READONLY_PATHS` validator for empty,
  absolute, dot-segment, trailing-slash, and duplicate entries.
- In `host/container-runtime.sh`, keep public configured `READONLY_PATHS`
  separate from runtime-owned `EFFECTIVE_READONLY_PATHS`. Its initializer resets
  only the effective array and mount arguments; it must not erase configuration
  already loaded. Remove `configure_readonly_paths`, `readonly_paths_contain`,
  and `ensure_readonly_stubs`.
- Add one `check_readonly_path` primitive that verifies lexical shape,
  existence, symlink components below the canonical project root, and canonical
  containment. Use it both in the pre-launch validation pass and the pre-mount
  recheck so the two passes cannot drift.
- Add a trusted-input classifier for the default config, selected configs, and
  Containerfiles. It distinguishes a valid directly external path from an
  in-project path without first following a project-controlled symlink. For an
  in-project input, reject symlink components, require canonical containment,
  and return the canonical project-relative path for the effective set.
- Preserve each trusted input's original spelling until classification; do not
  let the current `realpath` in `prepare_config_selection` erase the evidence
  needed to detect a project-controlled symlink. When the default config exists,
  classify it before parsing any selected config, including when `--config PATH`
  selects another file. Then classify the selected config before parsing it. In
  `build_or_select_dev_image`, run it after discovering the exact Containerfile
  and before constructing or executing `BUILD_CMD`. Store only the exact
  Containerfile actually used; selecting `DEV_IMAGE` stores none.
- Finalize `EFFECTIVE_READONLY_PATHS` after image selection from configured
  paths, the classified default-config path when present, the classified
  selected-config path, and the classified Containerfile path.
  Deduplicate destinations directly while preserving the order above. During
  the pre-mount recheck, run `check_readonly_path` for configured entries and
  rerun the trusted-input classifier on each automatic input's original
  spelling; checking only a previously canonicalized result would miss a
  replaced symlink.
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
  increment `WARNINGS`; remove the current "No read-only project paths were
  mounted" warning. Plan 1.1 makes the anchor mandatory and owns restoring an
  empty-set warning as an internal regression signal.
- Update the supported-settings header in `jailbox`, README configuration table,
  examples, recipes, and threat model. Remove claims about built-in protection
  and stub creation.

Do not retain `READONLY_EXTRA` as an alias. The strict parser reports it as an
unknown setting.

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
- preservation of configured order;
- read-only mount construction for files and directories;
- rejection of absolute, empty, dot-segment, trailing-slash, duplicate,
  missing, outside-project, and symlinked entries;
- rejection of leaf and intermediate-component symlinks;
- acceptance when only the canonical project root's host spelling has a
  symlinked prefix;
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
  host parses or builds them; and
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
