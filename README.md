# jAilbox

**Hardened Remote SSH development environments for your existing dev containers.**

[![PR checks](https://github.com/francoisnt/jailbox/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/francoisnt/jailbox/actions/workflows/pr-checks.yml)
[![Latest release](https://img.shields.io/github/v/release/francoisnt/jailbox)](https://github.com/francoisnt/jailbox/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

<!-- TODO: terminal recording / GIF of `jailbox` launching into the editor -->

jailbox wraps your project's development image with OpenSSH and runs it as a
hardened, rootless Podman container. It gives tools — especially AI coding
agents — your project's full toolchain while reducing host exposure:

- Read-only root filesystem, zero Linux capabilities, no privilege escalation
- No Docker/Podman sockets
- Optional egress control (domain allowlist enforced by a proxy sidecar)
- Clean separation between project files and runtime state

You keep the convenience of Remote SSH development; the agent loses most of
its reach into your machine.

---

## Requirements

- **Linux or macOS** with **Podman** (rootless preferred)
- **Bash 4.4 or newer** (`brew install bash` on macOS)
- `podman`, `ssh`, `ssh-keygen`, and either `sha256sum` or `shasum` (project
  identity is a SHA-256 hash of the project path)
- VS Code or VSCodium with the **Remote - SSH** extension (for the editor
  workflow)
- A project with a `Containerfile`/`Dockerfile` — or any public image name
  (see [Recipes](#recipes))

## Quick Start

### 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/francoisnt/jailbox/master/install.sh | bash
```

### 2. Use

```bash
cd /path/to/your/project
jailbox init
jailbox
```

`jailbox init` creates a minimal `jailbox.conf` without overwriting any existing
path. jailbox then discovers or builds your dev image, starts the hardened
container, and opens the project in VS Code or VSCodium via Remote SSH. Use
`jailbox up` instead to launch for terminal or automation use without requiring
or opening an editor.

### Updating

Re-run the install command above. It cleanly replaces the previous install
and never touches your `jailbox.conf`, containers, or images.

### Uninstalling

```bash
jailbox --uninstall
```

This removes the installed files and the `jailbox` command. Project
containers and images are left in place; remove them with `jailbox --clean`
per project (or `podman rm` / `podman rmi`) beforehand if you no longer
want them.

If modern Bash is unavailable, run the installed copy of
`install.sh --uninstall` directly; the installer remains compatible with the
macOS system Bash 3.2.

---

## Recipes

### Run an AI coding agent with egress control

The setup jailbox is built for. Run `jailbox init`, then edit `jailbox.conf`
in the project root to allow only the hosts your agent and toolchain need —
everything else is blocked at the network level:

```conf
# Claude Code + npm toolchain (check your agent's docs for its endpoints):
EGRESS_ALLOW=api.anthropic.com,claude.ai,statsig.anthropic.com,sentry.io,registry.npmjs.org,github.com
```

Launch with `jailbox`, open the integrated terminal, and run your agent
there. Requests to hosts outside the allowlist fail; see
[Troubleshooting](#troubleshooting) for how to spot and allow a blocked
domain. Without `EGRESS_ALLOW`, the container has unrestricted outbound
access — the rest of the hardening still applies, but for agent work the
allowlist is strongly recommended.

### Project without a Containerfile

Point jailbox at any image by adding one line to the generated config:

```bash
jailbox init
echo 'DEV_IMAGE=node:22-bookworm' >> jailbox.conf
jailbox
```

### Protect project files

Paths the host or CI later executes deserve read-only overlays inside the
container. List only paths that already exist in the project:

```conf
READONLY_PATHS=Makefile,.husky,scripts/deploy.sh
```

---

## Command Reference

```bash
jailbox init         # Create the default project configuration
jailbox              # Launch the environment (default; requires jailbox.conf)
jailbox up           # Launch without requiring or opening an editor
jailbox stop         # Remove containers, networks, and an opted-in ephemeral home
jailbox doctor       # Check SSH and editor integration status
jailbox ssh-config   # Show SSH configuration instructions
jailbox --clean      # Permanently delete home/runtime state and remove derived resources/images
jailbox --uninstall  # Remove the jailbox installation from this machine
```

### Lifecycle

`up` ensures the declared sandbox is ready. It creates an absent sandbox,
resumes compatible stopped containers, and reuses healthy running containers
without restarting them or rotating SSH credentials. Eligible partial states
are completed in dependency order: for example, a missing proxy can be created
on valid surviving networks. Missing networks beneath a surviving container,
damaged SSH material, changed policy, and unhealthy running
components refuse reuse without repair. Explicit replacement is:

```bash
jailbox stop
jailbox
```

Bare `jailbox` launches the sandbox and opens the configured editor. `jailbox
up` performs the same sandbox launch but does no editor discovery, editor
configuration, or editor launch; it returns once the sandbox is ready.
These two commands start containers and require configuration —
`JAILBOX_CONFIG_*` environment variables, or a `jailbox.conf` when none is
set (see Configuration). Bare launch opens the editor after successful
creation, resume, or reuse. Neither automatically replaces an
incompatible sandbox.

Before changing sandbox state, launch validates the complete resource inventory,
stored home policy, SSH generation, mounts, hardening, network attachments, and
independently observable running health. Readiness that depends on an eligible
missing or stopped component is checked after creation/start. Missing or stale
jailbox-managed downloader blocks are synchronized; correct blocks and unrelated
home contents are preserved. Required checks fail closed. External website
availability is advisory; failed DNS or transport is never proof of isolation
or proxy denial.

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

Concurrent lifecycle commands for one project are unsupported. They no longer
silently replace each other's containers, but they still race over shared SSH,
network, and image state; run one at a time.

**State**: per-project runtime state (SSH keys/config, editor profiles) lives
under `~/.local/state/jailbox/`; `--clean` removes the current project's
share of it, and `stop` removes SSH credentials while retaining unrelated state.
`init` writes only the new default `jailbox.conf`.

Each development-container object owns one SSH generation, prepared on the host
before creation. Its client private key, pinned server identity, and client
configuration stay host-only under the project's `ssh-generation/` directory.
Only server keys and authorized keys enter the container, through a read-only
mount. The keep-id user mapping preserves strict ownership; the authorized-keys
path and its parents are not group- or other-writable. Mutable daemon state
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

**Upgrade**: re-run the install command (see Quick Start); it replaces the
previous install cleanly.

**Uninstall**: `jailbox --uninstall` (delegates to the installed copy's
`install.sh --uninstall`, so the uninstall logic always matches the
installed version).
This command requires Bash 4.4 or newer; without it, run the installed
`install.sh --uninstall` directly.

### Configuration and version compatibility

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
listed in `READONLY_PATHS`, so the same content mounted from a different
project path is a different sandbox. Reordering `EGRESS_ALLOW` is stable,
because that allowlist is a set; reordering `READONLY_PATHS` is not, because
mount order can matter.

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

**Use `jailbox stop` followed by `jailbox up` to rebuild.** This removes the
existing containers and SSH credentials, builds from selected inputs, and
creates a new generation. Stop preserves persistent homes and deletes
ephemeral homes according to their recorded retention policy.

Builds can fetch missing base images and update the local image store and
derived tags. Automatic registry refresh is not performed; rebuilding does
not guarantee registry freshness or reproducibility. Persistent-to-ephemeral
changes and corrupt home metadata require warned `--clean` then `up`, since
stop preserves the blocking home. `--clean` permanently deletes the project's
home and runtime state.

---

## Configuration

jailbox has one canonical machine configuration model: declared
`JAILBOX_CONFIG_*` environment variables. When none is present, a temporary
adapter parses `jailbox.conf` into the same effective values instead — the
file remains the human editing surface, and a later release moves its parsing
into the editor frontend without affecting environment callers. The two
sources are exclusive: if any `JAILBOX_CONFIG_*` variable is set, it is the
complete configuration, the file is not read, and a notice on stderr says so.
`--config` cannot be combined with environment configuration.

### Environment configuration (`JAILBOX_CONFIG_*`)

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
  `JAILBOX_CONFIG_EDITOR`: `EDITOR` (in `jailbox.conf`) and `JAILBOX_EDITOR`
  are frontend-only inputs for the bare editor launch.

With environment configuration, `jailbox up` needs no `jailbox.conf` at all.
Only `up`, the bare editor launch, and (for now) `ssh-config` consume
configuration; `stop`, `doctor`, `init`, `--clean`, `--help`, and
`--uninstall` never read it.

### File configuration (`jailbox.conf`)

Without environment configuration, every launch requires a `jailbox.conf` in
the project root. Create the minimal default safely with `jailbox init`:

```conf
# Additional project paths mounted read-only inside the sandbox.
READONLY_PATHS=
```

`init` refuses to overwrite any existing file or other filesystem object. It
also requires both deterministic project container names to be absent: an
existing writable sandbox could otherwise alter the policy anchor while it is
being published. Clear those names with `jailbox stop`.

Configuration uses strict `KEY=value` lines (no shell syntax, values cannot
contain whitespace):

Use `jailbox --config PATH [COMMAND]` to select a different complete config
file. The option belongs to the file adapter: it fails when `JAILBOX_CONFIG_*`
environment configuration is present, and it moves to the editor frontend with
the rest of file handling. The option must precede the command; the selected
file replaces rather than merges with the project config. Relative settings still resolve from the
project root. The default `jailbox.conf` is still required when selecting an
external file; it remains a persistent read-only anchor so a sandbox cannot
plant policy for a later bare launch. The selected file is the only file
parsed. A selected config inside the project is also mounted read-only; an
external config is outside the project mount and needs no overlay.

Default, selected in-project, and directly selected external config paths
reject a symlink in any supplied path component. Pass the physical path to an
external config directly rather than a symlinked spelling.

| Key | Default | Purpose |
|---|---|---|
| `DEV_IMAGE` | — | Use this image instead of building one |
| `DEV_CONTAINERFILE` | auto-discovered | Containerfile to build the dev image from |
| `DEV_BUILD_CONTEXT` | project root | Build context for `DEV_CONTAINERFILE` |
| `DEV_TARGET_STAGE` | final stage | Multi-stage build target to use as dev image |
| `MEMORY_LIMIT` | `4g` | Development container memory limit (Podman `--memory` value) |
| `CPU_LIMIT` | `2` | Development container CPU limit (Podman `--cpus` value) |
| `PIDS_LIMIT` | `256` | Development container process-count limit (Podman `--pids-limit` value) |
| `EPHEMERAL_HOME` | `false` | Exact lowercase `true` or `false`; `true` makes the home belong to one container generation and deletes it on stop. Empty or other values are invalid. |
| `EDITOR` | `codium`, then `code` | Editor preference (`codium` or `code`); frontend-only, file-exclusive key |
| `EGRESS_ALLOW` | unset (unrestricted) | Comma-separated domain allowlist; enables egress control |
| `READONLY_PATHS` | — | Comma-separated existing project paths mounted read-only |

Resource-limit values are passed to Podman verbatim; Podman validates them
when the development container starts, so an unsupported value fails at
launch with Podman's own diagnostic. The proxy sidecar's resources are core
policy, not configuration.

Annotated example:

```conf
DEV_IMAGE=node:22-bookworm

# Or build from source:
DEV_CONTAINERFILE=./Dockerfile
DEV_TARGET_STAGE=dev

# Optional editor preference. Defaults to codium when available, then code.
EDITOR=codium

EGRESS_ALLOW=github.com,githubusercontent.com,api.github.com,claude.ai

# Existing paths to mount read-only. Every listed path must exist before launch.
READONLY_PATHS=Makefile,.husky,scripts/deploy.sh
```

Alpine-based dev images require `EDITOR=codium`: VS Code Remote SSH does not
support Alpine SSH hosts. See the [tested configurations](#tested-configurations)
matrix for the supported editor/OS combinations.

When `EGRESS_ALLOW` is configured, a bare editor launch automatically adds the
selected editor's Remote SSH bootstrap hosts so the editor can install its
remote server:

- `EDITOR=code`: `update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `main.vscode-cdn.net`, `vo.msecnd.net`
- `EDITOR=codium`: `github.com`, `githubusercontent.com`

`jailbox up` does not discover an editor, so it does not add these bootstrap
hosts; its filtered sandbox contains only the configured allowlist. After an
explicit `jailbox stop`, a bare `jailbox` launch creates a sandbox whose policy
also permits the selected editor's hosts. Without `EGRESS_ALLOW`, both commands
use the ordinary unrestricted network and no allowlist is rendered.

**How egress enforcement works:** When `EGRESS_ALLOW` is set, jailbox places
the container on an internal-only Podman network — created with no external
route and no DNS service. A tinyproxy sidecar is attached to both that
internal network and a separate external-facing network, and acts as the sole
outbound gateway at a fixed internal IP. Applications that ignore
`HTTP_PROXY`/`HTTPS_PROXY` cannot reach the public internet directly: the
internal network has no gateway, so outbound connections fail at the network
level regardless of proxy cooperation. tinyproxy enforces the domain
allowlist for all HTTP and HTTPS traffic that passes through it, and
restricts HTTPS CONNECT tunnels to port 443.

Without `EGRESS_ALLOW`, the container runs on a standard Podman network with
unrestricted outbound internet access.

---

## Security & Threat Model

### What jailbox does well
- Read-only root filesystem
- Zero capabilities + no-new-privileges
- Rootless Podman containers (`--userns=keep-id`)
- Fresh client and server SSH key pairs per container, with strict pinned host-key checking
- No container runtime sockets mounted
- Strict sshd configuration (key auth only, local forwarding only)
- Optional egress control: when `EGRESS_ALLOW` is set, the container is
  placed on an internal-only network with no direct external route and no
  DNS; an unprivileged tinyproxy sidecar is the only outbound gateway,
  accepts clients from the internal network only, and enforces the domain
  allowlist for HTTP/HTTPS

### Important realities
- The container runs with your **host UID**, so it can read and write your
  project files
- Project files are mounted writable. An existing default `jailbox.conf`, the
  selected in-project config, and the exact in-project Containerfile used for
  the build are overlaid read-only automatically. Selecting an external config
  does not remove protection from the default config.
- Launch requires that default config even when an external config is selected.
  Keeping this anchor present and read-only prevents the sandbox from creating
  policy that a later bare launch would trust.
- Only additional paths explicitly listed in `READONLY_PATHS` receive
  read-only overlays. They must already exist as regular files or directories;
  missing paths are rejected and no stubs are created. Every other project
  path, including unused Containerfile candidates, remains writable.
- Read-only overlays protect integrity, not secrecy: code in the sandbox can
  still read their contents.
- Paths are validated before launch and rechecked while mount arguments are
  assembled, but host-side filesystem races before Podman resolves each bind
  source are not eliminated.
- The AI (or any code running in the container) can still exfiltrate or
  destroy project contents
- You still share the kernel and container runtime trust boundary
- Persistent home contents are sandbox-controlled state retained across policy
  and version changes. They are not integrity-checked; use an ephemeral home
  when each new container generation should start with fresh home contents
- `stop` and `--clean` delete the project's exact derived Podman names using
  your own Podman authority. Neither a name nor a label can authenticate a
  resource against a host process that already holds that authority, so these
  commands are not a guard against other host-side processes. What jailbox
  does guarantee is that the sandbox never holds that authority: no
  container-engine socket is mounted into it
- Without `EGRESS_ALLOW`, the container has unrestricted outbound internet
  access
- Host services listening on `0.0.0.0` (local dev servers, LLM runtimes,
  databases) remain reachable from the container through the Podman bridge
  gateway IP — even in egress mode, since the internal network's bridge
  interface still exists on the host. Bind sensitive host services to
  `127.0.0.1` if the container must not reach them
- Egress enforcement is proxy-mediated (HTTP/HTTPS domain filter), not
  packet-level: tinyproxy only filters traffic that passes through it and
  cannot inspect TLS payload; allowed endpoints can still receive exfiltrated
  data; this is not equivalent to a firewall, VM network isolation, or
  kernel-enforced packet filtering
- In filtered mode, the effective allowlist depends on the launch command:
  bare `jailbox` includes the discovered editor's bootstrap hosts, while
  `jailbox up` does not. In particular, VSCodium adds `github.com` and
  `githubusercontent.com` to a bare-launch sandbox

jailbox focuses on reducing accidental host exposure and limiting common
container escape vectors, not defending against a determined kernel- or
runtime-level attacker. It provides much better defaults than running agents
directly on the host or in privileged containers, but it is **not** a full
sandbox.

---

## How It Works

jailbox follows a clean layered approach:

1. **Dev Image** — Uses or builds from your existing `Containerfile`/`Dockerfile`
2. **Wrapper Image** — Adds OpenSSH server, creates the managed `jailbox` user, and installs hardened sshd config
3. **Runtime** — Project mounted at `/home/jailbox/project` (writable) with selected paths overlaid read-only, plus a home volume that is persistent by default
4. **SSH & Editor** — Generates project-specific SSH state under `~/.local/state/jailbox/projects/` and VS Code/VSCodium user profiles under `~/.local/state/jailbox/editor-profiles/`

**What remains unavoidable** (due to Remote SSH limitations):
- An OpenSSH server is still required
- A generated SSH config is needed for dynamic ports and proxy settings
- jailbox uses per-project editor profiles to avoid mutating your normal VS Code settings

**What jailbox avoids**:
- Mutating host `~/.ssh/config`
- Mounting host `~/.gitconfig`; only `user.name` and `user.email` are copied into a generated config
- Mounting runtime sockets
- Dynamic sshd_config rewriting
- Overwriting `.vscode/settings.json`

### Project image requirements

- **Do not** create or rely on a custom user. jailbox always creates and runs
  as its own managed user called `jailbox` (with your host UID).
- Install all tools, language runtimes, and dependencies **globally**
  (system-wide) so they are available to the `jailbox` user.
- Include `bash` (preferred) or a working `/bin/sh`.
- Provide a supported package manager (`apt-get`, `apk`, `dnf`, or `yum`).

If your final stage is distroless or production-only, use `DEV_TARGET_STAGE`
to target a proper development stage.

---

## Troubleshooting

Start with `jailbox doctor` — it reports container status, SSH config, and
editor integration for the current project.

| Symptom | Cause / fix |
|---|---|
| `no Containerfile found` | Set `DEV_IMAGE=<image>` or `DEV_CONTAINERFILE=<path>` in `jailbox.conf` |
| `dev image has no usable shell` / `no supported package manager` | The selected image/stage is production or distroless; set `DEV_TARGET_STAGE` to a dev stage or use `DEV_IMAGE` |
| `managed user 'jailbox' already exists in the dev image` | Remove/rename that user in the dev image; jailbox manages its own user |
| `host UID N already belongs to existing image user` | Use a dev image where your UID is free; jailbox will not mutate existing users |
| `project sandbox container ... is still present` during `init` | Initialization requires absent containers; run `jailbox stop` before `init` |
| `refusing sandbox reuse` | Follow the stated recovery; `stop` preserves persistent homes and deletes ephemeral homes, while `--clean` permanently deletes home/runtime state |
| `sandbox convergence failed` | Startup or synchronization began before failure; read the cleanup and retained-resource report before retrying or performing recovery |
| `local port N is already in use` | Another process holds the project's derived SSH port; stop it and relaunch |
| `SSH generation is orphaned` | Credentials outlived their container; run `jailbox stop` (which removes them) then `jailbox up` |
| `SSH state path ... is a symlink` / `is not a directory` | jailbox will not read or delete credentials through a substituted path; replace that path with a real directory, or point `XDG_STATE_HOME` at one, then relaunch |
| A request from inside the container fails in egress mode | Check the proxy log: `podman logs <project>-proxy` (find the name with `podman ps`). Blocked hosts appear as `Proxying refused on filtered domain` — add the domain to `EGRESS_ALLOW` and relaunch |
| VS Code cannot connect to an Alpine-based container | VS Code Remote SSH does not support Alpine hosts; set `EDITOR=codium` |
| `neither 'codium' nor 'code' was found in PATH` | Install the VSCodium or VS Code CLI, or set `JAILBOX_EDITOR` |
| `sshd did not become ready in time` | Inspect the container log: `podman logs <container-name>` (printed in the error) |
| Editor shows `Unable to watch for file changes` | Host `fs.inotify.max_user_watches` is too low (jailbox warns below 524288); raise it persistently: `echo 'fs.inotify.max_user_watches=524288' \| sudo tee /etc/sysctl.d/60-jailbox-inotify.conf` then `sudo sysctl --system` |

---

## Why not Dev Containers?

jailbox is **not** a replacement for Microsoft's Dev Containers specification.

**Dev Containers** excel at team collaboration, standardized onboarding, and
rich configuration through `devcontainer.json`.

**jailbox** provides more **opinionated, hardened runtime defaults** focused
on reducing risk when running untrusted code (particularly AI agents). It
works with plain `Containerfile`/`Dockerfile` setups and adds optional egress
control.

**Many teams use both**:
- Dev Containers for regular development and consistency
- jailbox for AI-assisted coding sessions that benefit from stronger containment

---

## Tested Configurations

<!-- BEGIN GENERATED: tested-matrix -->
<!-- Generated by scripts/gen-tested-matrix.sh from versions.env. Edit those, then run: bash scripts/gen-tested-matrix.sh --write -->

The release gate installs the exact versions pinned in
[`versions.env`](versions.env) — editors, Remote SSH extensions, the
VSCodium REH server, and container base images — so a green gate vouches for
this specific matrix. A daily canary workflow tests every new upstream
release against the full suite and advances the pins automatically when it
passes; failures are tracked as `canary`-labeled issues. Alpine/VSCodium is
a best-effort tier: the pinned combination is release-blocking, while
latest-version failures only file issues.

| Container OS | VS Code 1.137.0 | VSCodium 1.135.06055 |
|---|---|---|
| Debian 12 | ✅ | ✅ |
| Alpine 3.21 | — | ✅ |
| Fedora 41 | ✅ | ✅ |

VS Code Remote SSH does not support Alpine SSH hosts; that combination is
covered by VSCodium only.

Remote extensions: `ms-vscode-remote.remote-ssh` 0.128.0
(VS Code), `jeanp413.open-remote-ssh` 0.3.1 (VSCodium).
VSCodium REH server: 1.135.06055 (commit `1a46a584725d5dd330e0bcd7f5510f24990efcf2`).

Last verified: 2026-09-10
<!-- END GENERATED: tested-matrix -->

---

## Contributing

### Versions and releases

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

Run `bash scripts/release.sh` to see the automatic selection, optionally raise
the bump, and confirm dispatch. Use `--bump minor` or `--bump major` to specify
a minimum explicitly; `--bump patch` is also accepted. The higher of the
automatic and requested bumps wins locally and in CI. `--yes` skips prompts;
`--dry-run` and `--print-version` are non-interactive and honor `--bump`.
The Actions Release workflow offers the same minimum-bump choice, defaulting
to `auto`. A major bump before 1.0 produces `v1.0.0`; `--first-major` remains
available only before 1.0 and cannot be combined with an explicit bump in
either entry path. Overrides apply only to their release request.

Release requests use ephemeral `release-request`, `release-request-first-major`,
or `release-request-bump-{patch,minor,major}` tags. They never participate in
version-tag discovery. CI runs all four release gates, then builds and
validates the final archive's stamp and `--version` output against the selected
version before creating the release tag. It publishes those same validated
archive bytes, the identical `latest` alias, and their checksums.

Development setup, repository layout, and test suites are documented in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Project Status

jailbox is usable today for real projects and is actively maintained, but
still evolving.

**Repository**: https://github.com/francoisnt/jailbox

## License

MIT
