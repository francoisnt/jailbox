# Config-file selection — `--config PATH`

## Goal

Allow a caller to select one complete configuration file, inside or outside the
project tree. This requirement covers only config-file selection; profiles,
sandbox identity, and running-sandbox reuse are outside its scope.

## CLI

```text
jailbox [--config PATH] [COMMAND] [ARGS...]
```

`--config PATH` is a leading global option. It must appear before the command.
The path names the exact config file to load instead of
`$PROJECT_DIR/jailbox.conf`.

Examples:

```sh
jailbox
jailbox --config ../lane.conf
jailbox --config config/lane.conf doctor
jailbox --config ../lane.conf --clean
```

`start`, `exec`, and `stop` may use the same leading option once those commands
exist; adding them is outside this plan.

## Semantics

- The config path must exist, be a readable regular file, and is canonicalized
  on the host before it is opened.
- The file is parsed by the existing strict `KEY=value` data parser. It is never
  sourced or evaluated as shell code.
- `--config` replaces, rather than merges with, the in-tree `jailbox.conf`.
- There is no inheritance key and no array merge behavior. Every selected file
  is complete, with omitted keys receiving the normal public defaults.
- Sandbox identity remains derived only from canonical `$PROJECT_DIR`. All
  configs selected for one worktree address the same sandbox; separate
  canonical worktree paths receive separate containers and runtime state. A
  later effective-config fingerprint may govern safe reuse, but mutable config
  contents never become part of resource names.
- Project-relative settings such as `READONLY_EXTRA` continue to resolve
  against canonical `$PROJECT_DIR`, not the config file's directory.
- A selected config inside the project is security-sensitive launch input. Its
  canonical project-relative path is added to `READONLY_PATHS` and overlaid
  read-only in the container like the default `jailbox.conf`.
- A selected symlink is followed to its canonical target. If that target is in
  the project, the target is protected read-only; the symlink pathname itself
  is not protected.

Only selected configs within the project require a read-only overlay; external
configs are already outside the container's project mount.

## Implementation

### Argument processing

Before loading configuration:

1. If the first token is `--config`, require and consume exactly one following
   path. `--config --help` is a missing-value error; use
   `--config PATH --help` for help with the global option present.
2. Parse the leading option directly in `main` and `shift` it there, so the
   remaining positional parameters are used consistently for command parsing,
   preflight, and dispatch without separate global argv state.
3. Reject another `--config`, a misplaced `--config`, an unknown leading
   option, and unexpected operands to existing commands.
4. Handle help before opening or parsing either the selected config or the
   default config. `--config PATH --help` therefore does not require `PATH` to
   exist, but it does require the option to have a syntactic value.
5. Load the selected file, or `$PROJECT_DIR/jailbox.conf` when absent.
6. Parse the remaining command and operands.

`--help` must describe the leading-option rule. Existing command behavior is
unchanged when `--config` is omitted.

Paths beginning with `-` are accepted as config values because the token after
`--config` is unambiguously its value, except for the reserved `--help` case
above. Paths may contain whitespace when passed as one shell argument.

### Path handling

- An explicit `--config` selection requires `realpath` before config loading
  rather than relying on the later command-specific preflight. Help requires
  neither `realpath` nor config-file access.
- Require the selected path to canonicalize successfully to a readable regular
  file. Symlinks are accepted subject to the in-project rule above.
- Keep the canonical selected path for loading while using the original
  `--config` argument in diagnostics, so errors name the selected file and line
  number rather than always saying `jailbox.conf line N`.
- Canonicalize `$PROJECT_DIR` before deciding whether the selected file is
  inside it. For an in-project selection, require one non-empty, safe
  project-relative path before adding it to `READONLY_PATHS`.

### Public API

- Add `--config` to the public CLI surface as a value-taking global option.
- Do not add profile-related public API.

## Tests

- With no option, `jailbox.conf` loads exactly as before.
- `--config PATH` loads only that file and leaves the working tree unchanged.
- Relative project settings resolve against the project, not the config file.
- Missing, unreadable, non-regular, duplicate, and misplaced `--config` inputs
  fail clearly.
- `--config` without a value fails; `--config PATH --help` succeeds without
  opening `PATH`; a path beginning with `-` and a quoted path containing spaces
  are accepted.
- Parser errors name the selected config rather than `jailbox.conf`.
- An in-project selected config is listed exactly once in the read-only mounts
  and cannot be modified, replaced, or removed from inside the runtime
  container.
- A selected symlink is accepted and its canonical target is protected when
  that target is inside the project. The symlink pathname itself is outside the
  protection contract.
- Existing commands reject unexpected operands instead of silently ignoring
  them.

## Non-goals

- No `jailbox.<name>.conf` discovery or profile token in the CLI grammar.
- No `EXTENDS`, config merging, or subtractive array syntax.
- No sandbox identity or running-sandbox reuse changes.
