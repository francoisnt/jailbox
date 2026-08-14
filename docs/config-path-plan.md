# Config-file selection — `--config PATH`

## Goal

Allow a caller to select one complete configuration file outside the project
tree. This requirement covers only config-file selection; profiles, sandbox
identity, and running-sandbox reuse are outside its scope.

## CLI

```text
jailbox [--config PATH] [COMMAND] [ARGS...]
```

`--config PATH` is a leading global option. It must appear before the command.
The path names the exact config file to load instead of
`$PROJECT_DIR/jailbox.conf`.

Examples:

```sh
jailbox start
jailbox --config ../lane.conf start
jailbox --config ../lane.conf exec -- pytest
jailbox --config ../lane.conf stop
jailbox --config ../lane.conf --clean
```

## Semantics

- The config path must exist, be a readable regular file, and is canonicalized
  on the host before it is opened.
- The file is parsed by the existing strict `KEY=value` data parser. It is never
  sourced or evaluated as shell code.
- `--config` replaces, rather than merges with, the in-tree `jailbox.conf`.
- There is no inheritance key and no array merge behavior. Every selected file
  is complete, with omitted keys receiving the normal public defaults.
- Project-relative settings such as `WRITABLE_PATHS` and `READONLY_EXTRA`
  continue to resolve against canonical `$PROJECT_DIR`, not the config file's
  directory.
- The config file is host-side input and is not mounted into the container.

## Implementation

### Argument processing

Before loading configuration:

1. If the first token is `--config`, require and consume exactly one following
   path.
2. Reject another `--config` or an unknown leading option.
3. Load the selected file, or `$PROJECT_DIR/jailbox.conf` when absent.
4. Parse the remaining command and operands.

`--help` must describe the leading-option rule. Existing command behavior is
unchanged when `--config` is omitted.

### Public API

- Add `--config` to the public CLI surface as a value-taking global option.
- Do not add profile-related public API.

## Tests

- With no option, `jailbox.conf` loads exactly as before.
- `--config PATH` loads only that file and leaves the working tree unchanged.
- Relative project settings resolve against the project, not the config file.
- Missing, unreadable, non-regular, duplicate, and misplaced `--config` inputs
  fail clearly.

## Non-goals

- No `jailbox.<name>.conf` discovery or profile token in the CLI grammar.
- No `EXTENDS`, config merging, or subtractive array syntax.
- No sandbox identity or running-sandbox reuse changes.
