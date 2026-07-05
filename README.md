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

- **Linux** with **Podman** (rootless preferred)
- `podman`, `ssh`, `ssh-keygen`
- VS Code or VSCodium with the **Remote - SSH** extension (for the editor
  workflow)
- A project with a `Containerfile`/`Dockerfile` — or any public image name
  (see [Recipes](#recipes))

## Quick Start

### 1. Install

```bash
curl -fsSLO https://github.com/francoisnt/jailbox/releases/latest/download/jailbox-latest.tar.gz
curl -fsSLO https://github.com/francoisnt/jailbox/releases/latest/download/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
release_dir="$(tar -tzf jailbox-latest.tar.gz | head -1 | cut -d/ -f1)"
tar -xzf jailbox-latest.tar.gz
cd "$release_dir"
./install.sh
```

### 2. Use

```bash
cd /path/to/your/project
jailbox
```

jailbox discovers or builds your dev image, starts the hardened container,
and opens the project in VS Code or VSCodium via Remote SSH. If your repo has
a `Containerfile` or `Dockerfile`, there is nothing to configure.

---

## Recipes

### Run an AI coding agent with egress control

The setup jailbox is built for. Create `jailbox.conf` in the project root and
allow only the hosts your agent and toolchain need — everything else is
blocked at the network level:

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

Point jailbox at any image with a one-line config:

```bash
echo 'DEV_IMAGE=node:22-bookworm' > jailbox.conf
jailbox
```

### Protect extra project files

Paths the host or CI later executes deserve read-only overlays inside the
container:

```conf
READONLY_EXTRA=Makefile,.husky,scripts/deploy.sh
```

---

## Command Reference

```bash
jailbox              # Launch the environment (default)
jailbox doctor       # Check SSH and editor integration status
jailbox ssh-config   # Show SSH configuration instructions
jailbox --clean      # Remove container, volume, networks and jailbox runtime state
```

**State**: per-project runtime state (SSH keys/config, editor profiles) lives
under `~/.local/state/jailbox/`; `--clean` removes the current project's
share of it. Nothing is written to your project except an optional
`jailbox.conf` you create and the protected-path stubs described in the
threat model.

**Upgrade**: install a newer release over the old one (`./install.sh` from
the new release directory).

**Uninstall**: `~/.local/share/jailbox/install.sh --uninstall`

---

## Configuration (`jailbox.conf`)

Optional `jailbox.conf` in the project root, strict `KEY=value` lines (no
shell syntax, values cannot contain whitespace):

| Key | Default | Purpose |
|---|---|---|
| `DEV_IMAGE` | — | Use this image instead of building one |
| `DEV_CONTAINERFILE` | auto-discovered | Containerfile to build the dev image from |
| `DEV_BUILD_CONTEXT` | project root | Build context for `DEV_CONTAINERFILE` |
| `DEV_TARGET_STAGE` | final stage | Multi-stage build target to use as dev image |
| `EDITOR` | `codium`, then `code` | Editor preference (`codium` or `code`) |
| `EGRESS_ALLOW` | unset (unrestricted) | Comma-separated domain allowlist; enables egress control |
| `READONLY_EXTRA` | — | Extra project paths mounted read-only (additive only) |

Annotated example:

```conf
DEV_IMAGE=node:22-bookworm

# Or build from source:
DEV_CONTAINERFILE=./Dockerfile
DEV_TARGET_STAGE=dev

# Optional editor preference. Defaults to codium when available, then code.
EDITOR=codium

EGRESS_ALLOW=github.com,githubusercontent.com,api.github.com,claude.ai

# Additional project paths to mount read-only inside the container, on top of
# the built-in protected set. Comma-separated, relative to the project root.
READONLY_EXTRA=Makefile,.husky,scripts/deploy.sh
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
- Project files are mounted writable; selected paths like `.git/config`,
  `.github/workflows`, and `Containerfile` are overlaid read-only. The
  built-in list is illustrative, not exhaustive — anything the host or CI
  later executes (`Makefile`, `.envrc`, `package.json` scripts, editor task
  files, …) is writable unless you add it via `READONLY_EXTRA`
- `READONLY_EXTRA` extends the built-in protected set and can never remove
  from it
- High-risk paths that are absent at launch (`.env`, `.github/workflows`,
  `.gitea/workflows`) are created as empty stubs so they can be mounted
  read-only; other absent paths — including `READONLY_EXTRA` entries, which
  produce a launch warning — are not protected
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
| `local port N is already in use` | Another process holds the project's derived SSH port; stop it and relaunch |
| A request from inside the container fails in egress mode | Check the proxy log: `podman logs <project>-proxy` (find the name with `podman ps`). Blocked hosts appear as `Proxying refused on filtered domain` — add the domain to `EGRESS_ALLOW` and relaunch |
| VS Code cannot connect to an Alpine-based container | VS Code Remote SSH does not support Alpine hosts; set `EDITOR=codium` |
| `neither 'codium' nor 'code' was found in PATH` | Install the VSCodium or VS Code CLI, or set `JAILBOX_EDITOR` |
| `sshd did not become ready in time` | Inspect the container log: `podman logs <container-name>` (printed in the error) |

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

Every release is gated on CI runs covering this matrix:

| Container OS | VS Code | VSCodium |
|---|---|---|
| Debian 12 (bookworm) | ✅ | ✅ |
| Alpine 3.21 | — | ✅ |
| Fedora 41 | ✅ | ✅ |

VS Code Remote SSH does not support Alpine SSH hosts; that combination is
covered by VSCodium only.

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
