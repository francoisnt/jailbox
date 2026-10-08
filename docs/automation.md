# Automation guide

[Home](../README.md) · [Development](development.md) · [Automation](automation.md) · [Security](security.md)

Use jailbox's core commands to manage development sandboxes from scripts or
an orchestrator. The same installed executable provides the editor workflow
and this machine interface; no separate service is required.

Core reads `JAILBOX_CONFIG_*` environment variables and never loads
`jailbox.conf`. It owns sandbox creation, validation, attachment, and cleanup.
Read the shared [security model](security.md) before choosing access policy.

- [First sandbox](#first-sandbox)
- [Environment configuration](#environment-configuration-jailbox_config_)
- [Command reference](#command-reference)
- [Connection metadata and local validation](#connection-metadata-and-local-validation)
- [Machine discovery and inventory](#machine-discovery-and-inventory)
- [Lifecycle](#lifecycle)
- [Configuration and version compatibility](#configuration-and-version-compatibility)
- [Versions and releases](#versions-and-releases)

## First sandbox

Follow the [installation instructions](../README.md#quick-start) and
[host requirements](development.md#requirements). Core needs no editor or Remote
SSH extension. Choose a [compatible development image](development.md#project-image-requirements).

In a Bash terminal, from the project you want to mount:

```bash
export JAILBOX_CONFIG_DEV_IMAGE=node:22-bookworm
jailbox validate
jailbox up
jailbox status
jailbox exec -- pwd
jailbox stop
```

Stop if any command fails. After a successful launch, status prints `running`,
and the example command prints `/home/jailbox/project`. Stop removes containers
and networks while retaining the default persistent home. Host project files
remain in place. This example permits project writes and unrestricted outbound
access; configure path and network restrictions before launch as needed.

Keep the same effective environment policy for `up`, `exec`, `shell`, and
`connection-info`. In scripts, check every exit status and stop dependent work
on failure. Serialize lifecycle operations for each project, including launch
and subsequent connection inspection. For an interactive login shell, run
`jailbox shell` before stopping, from a terminal.

For editor or SSH integrations, use `connection-info` to obtain validated
connection records. Its binary output and parsing contract are described below.

Machine commands consume only declared `JAILBOX_CONFIG_*` environment variables.
The frontend owns `jailbox.conf`: bare launch, `--no-editor`, and
`--config PATH validate` parse the selected file and pass composed policy to
machine commands as child processes. These file workflows replace inherited
`JAILBOX_CONFIG_*` entries, reporting ignored variable names on stderr without
printing values. Unrelated environment entries remain available to children.
Use `jailbox up` for environment-driven launches.

## Environment configuration (`JAILBOX_CONFIG_*`)

Every configuration key has exactly one derived spelling:

```bash
JAILBOX_CONFIG_DEV_IMAGE=node:22-bookworm \
JAILBOX_CONFIG_EGRESS_ALLOW_0=github.com \
JAILBOX_CONFIG_EGRESS_ALLOW_1=api.github.com \
JAILBOX_CONFIG_READONLY_PATHS= \
jailbox up
```

- Scalars: `KEY` becomes `JAILBOX_CONFIG_KEY`. An absent variable receives
  the key's default; a present empty variable is an empty value.
- Arrays: contiguous members `JAILBOX_CONFIG_KEY_0`, `JAILBOX_CONFIG_KEY_1`,
  … starting at zero, each non-empty; a bare empty `JAILBOX_CONFIG_KEY=`
  declares an explicitly empty array. Indices are `0` or a nonzero decimal
  without leading zeros; gaps, `_01`-style suffixes, mixing the bare form
  with indexed members, and non-empty bare variables are rejected before
  anything is mutated, naming the offending variable.
- Values are ordinary bytes including commas and spaces; any ASCII control
  character (including newline) is rejected. jailbox imposes no member-count
  maximum — total environment/argument size and host runtime capacity are the
  operational ceilings.
- Unknown `JAILBOX_CONFIG_*` names are rejected. There is no
  `JAILBOX_CONFIG_EDITOR`: file `EDITOR` selects the editor for bare launch.
  Inherited `JAILBOX_EDITOR` and shell `EDITOR` do not override that selection.

`jailbox up` never reads `jailbox.conf`, even when no environment keys are set.
`up`, `exec`, `shell`, `connection-info`, and plain `validate` consume environment
configuration; bare launch and `--no-editor` consume file configuration; `stop`, `status`, `config-schema`, `ssh-config`, `init`,
`--clean`, `--version`, `--help`, and `--uninstall` never read it.

The [configuration key table](development.md#file-configuration-jailboxconf)
lists defaults and meanings shared with file configuration; `EDITOR` is
frontend-only. Machine arrays use the indexed syntax above, not comma-separated
file syntax. Core automatically protects the selected in-project Containerfile;
it does not add the frontend's config-file protection or editor bootstrap hosts.

## Command reference

This is the complete CLI reference. Bare launch, `--no-editor`, `--config`,
and `init` belong to the [development workflow](development.md).

<!-- BEGIN GENERATED: public-api -->
<!-- Generated by scripts/gen-public-api.sh; run: bash scripts/gen-public-api.sh --write -->
```bash
jailbox --config PATH   # Load configuration from PATH instead of project jailbox.conf
jailbox up              # Launch the sandbox using environment configuration
jailbox stop            # Stop and remove this project's jailbox containers, networks, and ephemeral home
jailbox --clean         # Permanently delete this project's containers, networks, home, runtime state, and derived images
jailbox --no-editor     # Launch from the config file without opening an editor
jailbox exec            # Run a command: exec [--] CMD [ARG...]
jailbox shell           # Open an interactive login shell in a running sandbox
jailbox init            # Create the default project jailbox.conf
jailbox config-schema   # Print machine configuration key names and types
jailbox status          # Print this project's resource inventory state
jailbox connection-info # Print validated NUL-delimited SSH connection metadata
jailbox validate        # Check environment configuration and local launch inputs
jailbox ssh-config      # Print manual SSH config instructions for this project
jailbox --uninstall     # Remove this jailbox installation from the host
jailbox --version       # Show the build version without reading configuration
jailbox --help          # Show this help
```
<!-- END GENERATED: public-api -->

## Connection metadata and local validation

`jailbox exec [--] CMD [ARG...]` runs a non-interactive command in a healthy,
already-running sandbox using only `JAILBOX_CONFIG_*` environment policy.
It uses the same complete attachment checks as `connection-info`, and never
creates, starts, repairs, or replaces resources. Arguments after `exec` (and
its optional leading `--`) are passed literally, including empty arguments;
binary stdin belongs exclusively to the command, even during validation.
The installed Bash decoder starts the command in `/home/jailbox/project`.
No login shell is added: request one explicitly with
`jailbox exec -- bash -lc 'your command'` when needed. The SSH session retains
the generated uppercase and lowercase HTTP/HTTPS/NO_PROXY environment policy.

The Base64 argument frame is limited to 49,152 bytes; larger frames fail with
`argument list too long for jailbox exec`. SSH uses pinned host keys and no
PTY. The remote exit status is returned, with 255 ambiguous between a remote
exit and SSH failure. Ctrl-C ends local SSH promptly, but neither Ctrl-C nor
closing SSH guarantees signal delivery or termination of an unconfirmed remote
process. Coordinate lifecycle mutations separately from attachments.
Digest mismatch diagnostics list only recognized current invocation key names
in declaration order (or explicitly say none are present), never values.
Those names provide current-side context and cannot identify which launch-side
input differed; matching effective policy is required, regardless of provenance.

`jailbox shell` opens an interactive login Bash in an already-running compatible
sandbox. It requires terminals on both stdin and stdout, accepts no arguments
or `--config`, and uses only `JAILBOX_CONFIG_*` environment policy. Use the same
effective policy as launch, including any editor-added policy. It performs the
same attachment validation and digest diagnostics as `exec`; it never prompts
to launch or repair resources. An absent compatible sandbox needs an explicit
`jailbox up` before retrying. Other refusals explain the required recovery.

The shell starts in `/home/jailbox/project` with the SSH session environment,
including jailbox's proxy variables, before sandbox-local login startup files
run. A failed directory change aborts attachment. Startup files may customize
PATH, the working directory, and proxy variables; jailbox does not reset those
customizations afterward or load the host's login profiles. You can also use
your editor's terminal; shell adds no file-configured shortcut.

SSH allocates a remote PTY: terminal Ctrl-C interrupts the foreground remote
command, resizing propagates, and normal exit or disconnect restores the local
terminal. Signals sent directly to the local client retain ordinary SSH
behavior. The remote exit status is returned; 255 can also mean SSH failure.
Disconnecting does not guarantee termination of every remote process. Coordinate
lifecycle mutations separately from shell attachment, as with `exec`.

`jailbox connection-info` consumes only `JAILBOX_CONFIG_*` environment
configuration, including defaults when none is set. It validates the current
digest, every surviving policy-bearing resource, SSH generation, runtime
hardening, protected mounts, socket isolation, and live SSH/proxy/downloader
health without repairing or starting anything. Missing or stopped compatible
sandboxes and stale managed downloader settings need `up`; incompatible state
needs the recovery reported by the command, with recorded home retention or
deletion explained.

Success emits exactly these five records in order, each terminated by NUL,
with a literal TAB separating its name and verbatim value:

| Name | Value |
|---|---|
| `ssh_config` | Absolute validated generated client-config path |
| `ssh_host` | Exact generated host alias |
| `remote_path` | Absolute sandbox project path, currently `/home/jailbox/project` |
| `project_id` | First 12 lowercase hexadecimal SHA-256 characters of the canonical host project path |
| `proxy_url` | Live internal `http://<IPv4-address>:8888`, or empty without filtering |

The release version governs the schema. Consumers must require exit success,
split each NUL-delimited record on its first TAB, check names against
`[a-z][a-z0-9_]*`, reject duplicates, missing/out-of-order required fields,
invalid required values, and an unterminated final record. Unknown valid fields
may follow the required fields; their values are opaque. Values preserve all
accepted bytes, but framing does not widen configuration or SSH path syntax.
Use `IFS= read -r -d ''` or save stdout to a file: shell command substitution
cannot preserve NUL bytes. Failure emits diagnostics on stderr and no records.
Callers must serialize lifecycle changes per project and exclude them throughout
dependent inspection/attachment sequences, including the complete `up` then
`connection-info` interval. All callers, including other terminals and automation,
must cooperate: jailbox provides neither a lock nor an atomic multi-command
transaction. Successful attachment does not protect a long-lived session from
later lifecycle changes.

`jailbox validate` also consumes only environment configuration, ignoring even
a malformed `jailbox.conf`. It checks defaults, declarations, local paths and
protected launch inputs. Without `DEV_IMAGE`, a Containerfile and accessible
build context are required. Success certifies only configuration and local
inputs, not image contents, build success, port availability, editor readiness,
or sandbox health. It requires no Podman, SSH, editor, or project identity hash
and writes no state. `jailbox --config PATH validate` explicitly validates file
policy using headless composition; `connection-info` rejects `--config`.

`jailbox ssh-config` ignores configuration and needs neither Podman nor SSH.
It reports the identity-derived path and alias and a safely quoted SSH
`Include` instruction where representable. Path existence is not validation;
machine consumers must use `connection-info`. For editors, the
`remote.SSH.configFile` setting can point at the generated config.

## Machine discovery and inventory

`jailbox config-schema` prints one newline-terminated record per machine key:
the uppercase key name (`[A-Z][A-Z0-9_]*`), one literal TAB, then `scalar` or
`array`. Scalars appear in declaration order, followed by arrays in declaration
order; new keys are appended to their respective declaration arrays. Frontend
keys such as `EDITOR` are excluded. There are no headings, defaults, values,
colors, or diagnostics on stdout. Discovery needs no project configuration,
Podman, SSH, hash utility, or editor.

The jailbox release version governs this schema. Consumers should select a
compatible release range using `jailbox --version`, accept additional valid
keys within that range, and reject malformed records, duplicate keys, invalid
names, unknown types, and missing keys they require. Failed declaration
validation exits nonzero with diagnostics on stderr and empty stdout.

`jailbox status` uses the canonical physical current directory to identify the
project. On success it exits zero and prints exactly one word plus newline:

- `running`: the development container is running, regardless of support
  resource health or SSH damage.
- `stopped`: the development container is not running and at least one derived
  development/proxy container, plain/internal/external project network, or home
  volume exists.
- `absent`: none of those resources exists.

Images and host SSH/runtime state do not affect this inventory. A persistent,
legacy unlabeled, or corrupt-label home retained by `stop` yields `stopped`;
removing an ephemeral home with the other resources yields `absent`, as does
successful `--clean`. Status needs Podman and SHA-256 project identity hashing,
but no configuration, configuration digest, SSH, or editor. It does not repair
or mutate state, and it does not certify readiness to attach.

Failed identity derivation or required engine inspection exits nonzero, leaves
stdout empty, and reports the error on stderr. Consumers must check both the
exit status and exact output. Neither discovery command emits configuration
values or SSH material. Initialization is local and needs no inventory check.

## Lifecycle

`up` ensures the declared sandbox is ready. It creates an absent sandbox,
resumes compatible stopped containers, and reuses healthy running containers
without restarting them or rotating SSH credentials. Eligible partial states
are completed in dependency order: for example, a missing proxy can be created
on valid surviving networks. Missing networks beneath a surviving container,
damaged SSH material, changed policy, and unhealthy running
components refuse reuse without repair. Explicit replacement is:

```bash
jailbox stop
jailbox up
```

Bare `jailbox` launches the sandbox from `jailbox.conf` and opens the configured
editor. `jailbox --no-editor` uses the same file workflow without editor discovery,
bootstrap hosts, or editor launch. `jailbox up` launches using only
`JAILBOX_CONFIG_*` environment configuration. Bare launch opens the editor after
successful creation, resume, or reuse. It composes one environment and invokes
public `up` and then `connection-info` child processes, just as an external
orchestrator would. A failure from either command prevents editor launch. No
launch automatically replaces an incompatible sandbox.

Concurrent launches, stops, or cleans for one project are unsupported. The
frontend does not lock the interval from `up` through `connection-info` and
editor launch; coordinate other terminals and automation throughout that
sequence. Once connected, the editor session has no lifecycle protection:
another caller's `stop` or `--clean` disconnects it.

Before changing sandbox state, launch validates the complete resource inventory,
stored home policy, SSH generation, mounts, hardening, network attachments, and
independently observable running health. Readiness that depends on an eligible
missing or stopped component is checked after creation/start. Missing or stale
jailbox-managed downloader blocks are synchronized; correct blocks and unrelated
home contents are preserved. Required checks fail closed. External website
availability is advisory; failed DNS or transport is never proof of isolation
or proxy denial. Attachment checks retain the required local security checks
but do not probe the availability of allowed websites.

`stop` removes the development and proxy containers and all three project
networks. The home is persistent by default; a home created with
`EPHEMERAL_HOME=true` is removed last. Images and unrelated project runtime
files are preserved; SSH-generation material is removed after the development
container. The next launch creates fresh containers and rotates both client
and server key pairs. Stop is idempotent, succeeds when either or both containers
are already gone, and never reads or creates configuration, so it stays usable
when `jailbox.conf` is missing or malformed.

Because nothing is kept alive as a fallback, a launch that fails after
`jailbox stop` — a broken dev image build, for example — leaves no sandbox
running. Run `jailbox` again once the build is fixed.

`--clean` is the full teardown: containers, the home volume, all three
project networks, the project's runtime state, and the exact derived dev,
wrapper, and proxy image names. It warns that the home and runtime state are
permanently deleted. An external `DEV_IMAGE` is untouched unless deliberately
named as one of those three derived images.

Both commands act on the project's exact derived names and on nothing else —
the two containers, three networks, and home (subject to stored retention for
`stop`), plus the three derived images for `--clean`. They never read
configuration and never compute the configuration digest, so they stay usable
when `jailbox.conf` is missing or malformed; whatever occupies one of those
names is removed, regardless of what created it. Every target is probed before
anything is deleted; stop also reads home metadata first. A probe or required
metadata inspection failure aborts without deletion. A later removal failure
reports an error and leaves a partially completed cleanup that can be retried.

New homes record `jailbox.ephemeral-home=true|false` at creation. Stop follows
that stored value, independently of current configuration. Unlabeled legacy
homes remain unlabeled and persistent. A present invalid label (including an
empty value) makes stop warn and preserve the home; launch refuses it with
warned `--clean` then `up` guidance. A metadata inspection error never counts
as a legacy or corrupt label.

Changing persistent or legacy homes to ephemeral requires explicit `--clean`
then `up`, permanently deleting the existing home and runtime state. Changing
ephemeral homes to persistent uses `stop` then `up`. An ephemeral home left
without its development-container object is never reused: run `stop` to remove
it before `up`, even when requesting the same mode. These home refusals take
precedence over a configuration digest mismatch; cleanup never runs
automatically.

The names are derived from the SHA-256 hash of the project's physical path, so
an unrelated occupant is improbable — but if one exists, `stop` or `--clean`
will delete it. That is a deliberate trade: a name-collision check could not be
a security boundary anyway. Names and labels cannot authenticate a resource
against any process running with your Podman authority, which is exactly the
authority these commands use. jailbox's containment comes from mounting no
container-engine socket into the sandbox, so the sandbox never holds that
authority in the first place; guarding host-side deletions against other
host-side processes is a different threat boundary, and not one jailbox
claims.

**State**: host state lives under `${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/`.
Core runtime state, including SSH keys/config, is under `projects/<project-id>/`;
`--clean` removes that directory, and `stop` removes SSH credentials while
retaining unrelated runtime files. Frontend profiles live separately under
`editor-profiles/<project-id>/` and remain after both commands. `init` writes
only the new default `jailbox.conf`.

Each development-container object owns one SSH generation, prepared on the host
before creation. Its client private key, pinned server identity, and client
configuration stay host-only under the project's `ssh-generation/` directory.
Only server keys and authorized keys enter the container through a read-only
mount. Jailbox passes the proxy address through the container environment;
startup validates it and configures SSH to supply session proxy variables even
when an editor's SSH client does not forward them. Reuse validates the container's
proxy address against the current policy. The keep-id user mapping preserves
strict ownership; the authorized-keys path and its parents are not group- or
other-writable. Mutable daemon state
lives separately on a private, managed-user-owned `/run` tmpfs. Startup validates
authentication material and never repairs it or generates replacement keys.

Restarting the same container retains its identities. Orphaned complete or
partial SSH material blocks new creation: use `stop` then `up`. Compatibility
refusal preserves existing sandbox resources and generation files. Failure
after an allowed start is different: a surviving container is never
automatically stopped or deleted, even if this invocation started it. It may
remain running or have exited; process state, tmpfs, and startup home writes
are not restored. Managed downloader synchronization may have completed.

Handled failures remove only invocation-created resources that survivors no
longer need, removing containers before their credentials. A new proxy needed
by a surviving development container is retained, as is authentication material
when container removal fails. Diagnostics report retained objects, observed
states, cleanup failures, and explicit recovery. Forced termination may leave
partial state for the same inspection and recovery rules. Stop retains or
deletes the home according to its recorded policy.

## Configuration and version compatibility

Every project resource that outlives a single launch — both containers and all
three project networks — carries a `jailbox.config-digest` label: a SHA-256
digest of the exact jailbox version, the effective machine configuration
values, and the identity of the selected Containerfile. A launch recomputes
that digest and refuses before creating or reusing anything when a surviving
resource carries a missing, malformed, or different one. `jailbox stop`
clears incompatible containers and networks while preserving persistent homes.
The comparison includes resources outside the requested network mode.
Resources created by
a jailbox release from before the digest carry no label at all, so they are
incompatible too; the refusal names each one and the command that clears it.

The home volume is deliberately exempt from the digest. Its retention metadata
is checked separately, and its containment comes from the mount and runtime
policy applied at every launch. Persistent home content therefore survives
configuration and version changes.

**The digest covers references, not content.** A mutable or re-pulled
`DEV_IMAGE` tag, edited Containerfile bytes, and changed build-context
contents never change it; the configured values and the Containerfile's path
do. `jailbox.conf` formatting — quoting, spacing, comments, an explicitly
spelled default — does not change it either, because the digest is taken over
effective values. A path is not formatting: it reaches the digest when it is
listed in `READONLY_PATHS`, `WRITABLE_PATHS`, or `HIDDEN_PATHS`, so the same content mounted
from a different project path is a different sandbox. Reordering `EGRESS_ALLOW`
is stable because that allowlist is a set. All three path arrays are serialized in
declared order, so reordering any of them changes the digest.

**Version binding is deliberately conservative.** It stops a new release from
resuming containers whose immutable Podman settings were created under older
hardening rules, so a stamped release and a development build never share a
digest, and neither do two different stamped releases. Every unstamped build
reports the same `dev` token — including an install made from a source
checkout — so distinct source revisions are not distinguished by the digest.

**Ordinary reuse does not build images.** `up` and bare launch validate
configuration, resource compatibility, SSH, and runtime security, then reuse or
resume existing containers. They build only the images needed for missing
containers. Edited Containerfiles, copied build-context files, and manually
re-pulled image tags alone do not prevent reuse or update existing containers.

**Use `jailbox stop` followed by your original launch command to rebuild.** This removes the
existing containers and SSH credentials, builds from selected inputs, and
creates a new generation. Stop preserves persistent homes and deletes
ephemeral homes according to their recorded retention policy.

Builds can fetch missing base images and update the local image store and
derived tags. Automatic registry refresh is not performed; rebuilding does
not guarantee registry freshness or reproducibility. Persistent-to-ephemeral
changes and corrupt home metadata require warned `--clean` then `up`, since
stop preserves the blocking home. `--clean` permanently deletes the project's
home and runtime state.

## Versions and releases

`jailbox --version` prints one line, such as `jailbox 0.8.0`, without reading
project configuration, requiring Podman, or changing runtime state. Unstamped
source checkouts and installations made from them print `jailbox dev`. Release
packages carry a `VERSION` build artifact; install and update preserve it.
A malformed stamp fails with a diagnostic on stderr and no stdout output.
Do not add a `VERSION` file to source: packaging refuses an existing stamp.

The release version is also the API/schema version. Before 1.0, interface
additions receive patch bumps and removals or breaking changes require minor
bumps. Consumers can pin a minor line, for example `>=0.8.0,<0.9.0`. After
1.0, additions require minor bumps and breaking changes require major bumps;
consumers can pin a major line. Automatic comparison detects configuration-key
and CLI declaration names. Maintainers must review behavior, environment keys,
machine schemas, and accepted configuration grammar too: tightening validation
can break existing inputs without changing a declaration name.


### Installing a fixed release

The published installer downloads the latest release by default, including when
you save it and rerun it later. To select a fixed release, set
`JAILBOX_RELEASE_BASE_URL` on the Bash process running the installer. For example,
replace `v0.8.0` with your chosen published tag:

```bash
curl -fsSL https://github.com/francoisnt/jailbox/releases/latest/download/install.sh | \
  JAILBOX_RELEASE_BASE_URL=https://github.com/francoisnt/jailbox/releases/download/v0.8.0 bash
```

Each release contains its own `jailbox-latest.tar.gz` alias and `SHA256SUMS`.
The override selects both files from that release. With the default latest URL,
a release published between the two downloads can cause a checksum mismatch;
installation stops before replacing the installed copy. Retry the command.
