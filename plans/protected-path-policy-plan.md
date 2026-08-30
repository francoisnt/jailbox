# Explicit read-only project paths

## Goal

Replace jailbox's built-in protected-path list and additive `READONLY_EXTRA`
setting with one explicit `READONLY_PATHS` configuration setting. Validate every
configured entry before launch and mount every valid entry read-only.

This change does not redesign container lifecycle, configuration-file creation,
resource ownership, or concurrent-launch behavior.

## Configuration

`READONLY_PATHS` is a comma-separated array in jailbox's strict configuration
format:

```conf
READONLY_PATHS=jailbox.conf,.env,.github/workflows,.git/config,.git/hooks
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

## Behavior

The effective read-only set is exactly `READONLY_PATHS`. jailbox does not add
the selected config, Containerfile, `.env`, Git files, workflow directories, or
its own source tree automatically.

Validation runs at the start of sandbox launch, before image builds, network
creation, SSH credential generation, volume creation, or container creation.
Commands that do not launch a sandbox retain their current behavior and do not
perform path existence or symlink validation.

Construct one `:Z,ro` bind mount for every validated entry, preserving
configuration order. Recheck each entry with the same validation primitive
immediately before constructing its mount argument. This narrows, but does not
eliminate, the race before Podman resolves the source path; host processes and
an existing writable sandbox can still change project paths during launch.
Lifecycle locking and an explicit-stop requirement are separate work.

jailbox no longer creates `.env` or workflow-directory stubs. A configured path
must already exist. If a path does not exist, it cannot be protected by this
mechanism and code in the sandbox may create it later.

Projects that want to prevent the sandbox from changing policy for the next
launch must explicitly include `jailbox.conf` in `READONLY_PATHS`. Projects that
want to protect a Containerfile or other host-consumed project input must list
it explicitly as well.

## Implementation

- In `host/public-api.sh`, replace `READONLY_EXTRA` with `READONLY_PATHS` in
  `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`, default assignment, and generated
  public-API expectations.
- In `host/common.sh`, assign parsed array values to `READONLY_PATHS`. Replace
  `validate_readonly_extra` with a lexical `READONLY_PATHS` validator for empty,
  absolute, dot-segment, trailing-slash, and duplicate entries.
- In `host/container-runtime.sh`, remove the current internal `READONLY_PATHS`
  declaration and reset so configuration loading owns that array. Remove
  `configure_readonly_paths`, `readonly_paths_contain`, and
  `ensure_readonly_stubs`.
- Add one `check_readonly_path` primitive that verifies lexical shape,
  existence, symlink components below the canonical project root, and canonical
  containment. Use it both in the pre-launch validation pass and the pre-mount
  recheck so the two passes cannot drift.
- Keep `READONLY_MOUNTS` as container-runtime state. `build_readonly_mounts`
  resets it and emits a `-v` argument for every configured entry; it no longer
  skips absent paths or prints the old `READONLY_EXTRA` warning.
- In `jailbox`, remove `configure_readonly_paths` from
  `initialize_launch_state` and `ensure_readonly_stubs` from `run_launch`. Add
  configured-path validation at the beginning of `run_launch`, before
  `check_local_port_available` and all launch side effects.
- In `host/validation.sh`, continue checking the configured `READONLY_PATHS`
  mounts. Preserve its empty-set warning only if it remains useful; an empty set
  is now valid and must not be reported as a user error.
- Update the supported-settings header in `jailbox`, README configuration table,
  examples, recipes, and threat model. Remove claims about built-in protection
  and stub creation.

Do not retain `READONLY_EXTRA` as an alias. The strict parser reports it as an
unknown setting.

## Security documentation

Update the README threat model to state plainly:

- only paths explicitly listed in `READONLY_PATHS` receive read-only overlays;
- the writable project mount can change every other project path, including
  `jailbox.conf` and Containerfiles when they are not listed;
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
- absence of built-in paths when `READONLY_PATHS` is empty;
- absence of `.env` and workflow stub creation; and
- enforcement of every configured overlay in a running sandbox.

Run `tests/run portable`. Also run `tests/run runtime` because this changes
project mounts and the documented security contract.

## Non-goals

- Automatically protecting config files, Containerfiles, or other launch
  inputs.
- Creating a default `jailbox.conf`.
- Adding `jailbox stop` or changing `--replace` behavior.
- Changing cleanup or Podman resource-ownership rules.
- Adding lifecycle locks or closing filesystem race windows.
- Writable project lanes.
