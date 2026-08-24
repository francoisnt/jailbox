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

The effective set is:

1. every configured `READONLY_PATHS` entry;
2. the selected config file when it resolves inside the project; and
3. the exact Containerfile used to build the development image when it resolves
   inside the project.

Initialize and validate configured paths after project and config loading.
Finalize the effective set after `build_or_select_dev_image` identifies the
exact Containerfile, then construct the overlays. Deduplicate identical mount
destinations while preserving deterministic order.

An external selected config or Containerfile is not reachable through the
project mount and receives no project overlay.

## Configuration-file behavior

Bare `jailbox` and `jailbox up` atomically create the default
`$PROJECT_DIR/jailbox.conf` before config loading when it is absent:

```conf
# Project paths that jailbox must mount read-only.
READONLY_PATHS=
```

Create the complete contents in the project directory and publish them with an
atomic no-replace operation. Never overwrite an existing path. If another
process wins the race, discard the temporary file and load the winning file
through normal validation. Clean up temporary files on every failure path.

The generated config is part of the effective protected set and is mounted
read-only in the sandbox. This prevents code inside the sandbox from creating
launch policy that the host would trust on the next invocation.

`exec` and `shell` require the default config to exist and direct the user to
`jailbox up` when it is absent. Other lifecycle and inspection commands do not
create it. An explicitly selected `--config PATH` must exist and is never
created.

## Public API and implementation

- Add `READONLY_PATHS` to `CONFIG_ARRAY_KEYS`, defaults, parser assignment,
  help, documentation, and generated public-API expectations.
- Remove `READONLY_EXTRA` from `CONFIG_ARRAY_KEYS`, `CONFIG_DEFAULTS`,
  `set_config_array`, validation, help, README examples, tests, and generated
  public-API expectations. Do not retain it as an alias: the strict parser
  reports it as an unknown key.
- Replace internal names derived from the old API with names that distinguish
  configured paths from the finalized effective path set. Keep
  `READONLY_PATHS` as the public configured array and rename the current
  host/container-runtime-owned effective array to `EFFECTIVE_READONLY_PATHS`.
  `host/common.sh` validates configured entries; `host/container-runtime.sh`
  owns finalization, deduplication, mount construction, and runtime validation
  inputs.
- Add the default-config template and an atomic no-replace creation helper used
  only by bare launch and `up` before config loading.
- Use one lexical validator and one canonical containment helper for all
  project-relative mount inputs.
- Separate configured paths from the finalized effective mount list so image
  discovery can add only the Containerfile actually used.
- Build read-only overlays only after all validation succeeds.
- Keep configuration a strict data format; never evaluate path values as shell
  code or use them as unvalidated associative-array subscripts.
- Include `READONLY_PATHS` automatically in the command-mode config digest by
  iterating `CONFIG_ARRAY_KEYS`.

Review the generated public-API diff and release documentation because removing
`READONLY_EXTRA` and adding `READONLY_PATHS` changes the configuration surface.
The release notes must identify the key replacement and the new existence
requirement so existing configurations can be updated before launch.

## Documentation

Update the README examples and threat model to state that project policy paths
are protected through `READONLY_PATHS`. Document the automatic config and
Containerfile entries and the requirement that every configured path already
exist.

The threat model must remain explicit that the writable project mount permits
changes to any path outside the effective set and that read-only overlays do not
make other project content secret.

## Tests

- Empty `READONLY_PATHS` loads successfully.
- `READONLY_EXTRA` is rejected as an unknown key, is absent from help and
  documentation, and appears as removed in the generated public-API diff.
- Bare launch and `up` create the complete default config when absent and load
  it before continuing.
- Concurrent creators preserve one complete winning file without overwrite,
  partial content, or leftover temporary files.
- `exec`, `shell`, lifecycle, and inspection commands never create a config;
  attach commands fail with the `jailbox up` instruction when it is absent.
- Explicitly selected configs are never created.
- Multiple entries preserve order and receive read-only mounts.
- Absolute, traversing, dot-segment, trailing-slash, duplicate, missing, and
  symlinked entries are rejected.
- A symlink to a host path outside the project can never become a mount source.
- The selected in-project config is protected and an external config is not
  added to the project overlays.
- Only the exact in-project Containerfile used for the build is protected
  automatically.
- Every effective entry is read-only in a running sandbox.
- Tightening `READONLY_PATHS` changes the config digest, preventing `exec` or
  `shell` from attaching until the sandbox is relaunched.

Run `tests/run portable` and, because this changes project mounts and the
security contract, `tests/run runtime` wherever Podman is available.

## Non-goals

- Writable project lanes; those are defined in `writable-paths-plan.md`.
- Hiding project content from reads.
- Creating absent project paths.
