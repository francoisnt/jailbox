# External config selection — `--config <path>`

## Decision

jailbox will not implement named profiles, profile inheritance, or profile-aware
resource identity. Those features add command ambiguity, merge semantics, and
another concurrency model to a security-sensitive Bash CLI.

One canonical project directory continues to identify one sandbox. Callers that
need concurrent or independently configured sandboxes create separate checkouts.
Each checkout naturally receives distinct container, volume, network, SSH-state,
and port identities through the existing project-path hash.

This spec retains only the useful primitive from the profiles proposal:
selecting one complete config file outside the project tree.

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
- Resource identity remains derived solely from `$PROJECT_DIR`. Two different
  configs used from the same checkout target the same sandbox and must not be
  treated as concurrent identities.
- A running sandbox may be reused only when its recorded effective-config
  fingerprint matches the requested configuration. Otherwise jailbox replaces
  it before running a command. This prevents a tightened config from silently
  reusing an older sandbox with broader write or egress permissions.

The effective fingerprint covers every setting that affects the container,
mounts, networking, SSH session environment, editor integration, selected dev
image/build inputs, and the jailbox implementation version. It must not include
secrets or raw config-file contents in a container label; store a digest only.

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
- Do not add `EXTENDS`, profile globals, profile discovery, reserved-name
  scanning, or profile-aware hashing.

### Configuration fingerprint

Render effective settings in a fixed key order and hash that representation.
Array order remains meaningful unless the setting already has documented set
semantics. Record the digest on the container and proxy. Before reuse, require:

- the expected container and proxy topology exists;
- the container is running and answers SSH;
- every relevant digest matches the requested digest.

Any absent, malformed, or mismatched digest is a cache miss and triggers normal
replacement. It is never a reason to reuse uncertain state.

## Tests

- With no option, `jailbox.conf` loads exactly as before.
- `--config PATH` loads only that file and leaves the working tree unchanged.
- Relative project settings resolve against the project, not the config file.
- Missing, unreadable, non-regular, duplicate, and misplaced `--config` inputs
  fail clearly.
- Two external configs used from one checkout address the same resource names.
- Separate checkout paths receive distinct resource names and ports.
- An unchanged effective config reuses a healthy running sandbox.
- Tightening `WRITABLE_PATHS` or `EGRESS_ALLOW` changes the digest and replaces
  the running sandbox before `exec`.

## Non-goals

- No `jailbox.<name>.conf` discovery or profile token in the CLI grammar.
- No `EXTENDS`, config merging, or subtractive array syntax.
- No multiple sandbox identities for one checkout.
- No orchestration, checkout creation, scheduling, or task loops.
