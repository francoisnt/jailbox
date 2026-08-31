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
- `podman`, `ssh`, `ssh-keygen`
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
container, and opens the project in VS Code or VSCodium via Remote SSH.

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
jailbox stop         # Stop and remove this project's containers
jailbox doctor       # Check SSH and editor integration status
jailbox ssh-config   # Show SSH configuration instructions
jailbox --clean      # Remove container, volume, networks and jailbox runtime state
jailbox --uninstall  # Remove the jailbox installation from this machine
```

### Lifecycle

Launch requires both of the project's containers to be absent. jailbox never
replaces a running sandbox, so relaunching is a two-command operation:

```bash
jailbox stop
jailbox
```

`stop` removes only the ephemeral development and proxy containers. The home
volume, networks, images, and the project state directory are preserved —
the next launch creates fresh containers and rotates the SSH key pair. It is
idempotent, succeeds when either or both containers are already gone, and
never reads or creates configuration, so it stays usable when `jailbox.conf`
is missing or malformed. There is deliberately no flag that relaunches over a
running sandbox.

Because nothing is kept alive as a fallback, a launch that fails after
`jailbox stop` — a broken dev image build, for example — leaves no sandbox
running. Run `jailbox` again once the build is fixed.

`--clean` is the full teardown: containers, the home volume, all three
project networks, and the project's runtime state. Images are not removed.

Both commands prove ownership from the `jailbox.project` label rather than
from the derived resource name. `--clean` inspects every container, the home
volume, and every project network before deleting anything; a single
unlabelled or foreign resource aborts the whole operation with nothing
removed. Neither command will touch a resource jailbox does not own — resolve
those name collisions with Podman directly (`podman rm`, `podman volume rm`,
`podman network rm`).

Concurrent lifecycle commands for one project are unsupported. They no longer
silently replace each other's containers, but they still race over shared SSH,
network, and image state; run one at a time.

**State**: per-project runtime state (SSH keys/config, editor profiles) lives
under `~/.local/state/jailbox/`; `--clean` removes the current project's
share of it, and `stop` leaves it in place. `init` writes only the new default
`jailbox.conf`.

**Upgrade**: re-run the install command (see Quick Start); it replaces the
previous install cleanly.

**Uninstall**: `jailbox --uninstall` (delegates to the installed copy's
`install.sh --uninstall`, so the uninstall logic always matches the
installed version).
This command requires Bash 4.4 or newer; without it, run the installed
`install.sh --uninstall` directly.

---

## Configuration (`jailbox.conf`)

Every launch requires a `jailbox.conf` in the project root. Create the minimal
default safely with `jailbox init`:

```conf
# Additional project paths mounted read-only inside the sandbox.
READONLY_PATHS=
```

`init` refuses to overwrite any existing file or other filesystem object. It
also requires both deterministic project container names to be absent: an
existing writable sandbox could otherwise alter the policy anchor while it is
being published. Clear an existing project sandbox with `jailbox stop`; a name
collision with a container jailbox does not own must be resolved with Podman
directly.

Configuration uses strict `KEY=value` lines (no shell syntax, values cannot
contain whitespace):

Use `jailbox --config PATH [COMMAND]` to select a different complete config
file. The option must precede the command; the selected file replaces rather
than merges with the project config. Relative settings still resolve from the
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
| `EDITOR` | `codium`, then `code` | Editor preference (`codium` or `code`) |
| `EGRESS_ALLOW` | unset (unrestricted) | Comma-separated domain allowlist; enables egress control |
| `READONLY_PATHS` | — | Comma-separated existing project paths mounted read-only |

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

When `EGRESS_ALLOW` is configured, jailbox automatically adds the selected
editor's Remote SSH bootstrap hosts so the editor can install its remote server:

- `EDITOR=code`: `update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `main.vscode-cdn.net`, `vo.msecnd.net`
- `EDITOR=codium`: `github.com`, `githubusercontent.com`

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
- Fresh SSH keypair per launch, pinned host keys
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
3. **Runtime** — Project mounted at `/home/jailbox/project` (writable) with selected paths overlaid read-only, plus a persistent home volume for the jailbox user
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
| `project sandbox container ... is still present` | A previous sandbox is still running; run `jailbox stop`, then launch again |
| `container name ... is already used by a container jailbox does not own` | Something outside jailbox holds the derived name; inspect it with `podman inspect <name>` and remove it yourself |
| `refusing to remove resources jailbox does not own` | `stop`/`--clean` found an unlabelled or foreign container, volume, or network; remove the named resources with Podman |
| `local port N is already in use` | Another process holds the project's derived SSH port; stop it and relaunch |
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

| Container OS | VS Code 1.135.0 | VSCodium 1.126.04524 |
|---|---|---|
| Debian 12 | ✅ | ✅ |
| Alpine 3.21 | — | ✅ |
| Fedora 41 | ✅ | ✅ |

VS Code Remote SSH does not support Alpine SSH hosts; that combination is
covered by VSCodium only.

Remote extensions: `ms-vscode-remote.remote-ssh` 0.128.0
(VS Code), `jeanp413.open-remote-ssh` 0.3.1 (VSCodium).
VSCodium REH server: 1.126.04524 (commit `4c0b0c6cc561d2d3636d1ec250935431876ce4dc`).

Last verified: 2026-08-27
<!-- END GENERATED: tested-matrix -->

---

## Contributing

Development setup, repository layout, and test suites are documented in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Project Status

jailbox is usable today for real projects and is actively maintained, but
still evolving.

**Repository**: https://github.com/francoisnt/jailbox

## License

MIT
