# jAilbox

**Hardened Remote SSH development environments for your existing dev containers.**

jAilbox wraps your project's development image with OpenSSH and runs it as a **hardened, rootless Podman container**. It provides safer default isolation for running tools — especially AI coding agents — with access to your project's full toolchain while reducing host exposure.

---

## Why jAilbox matters

AI coding tools can execute and modify code autonomously, which introduces new risks when they have broad access to your machine. jAilbox addresses this by running everything inside a container that follows strict defaults:

- Read-only root filesystem
- Zero Linux capabilities
- No Docker/Podman sockets
- Controlled egress (optional)
- Clean separation between project files and runtime state

This gives you the convenience of Remote SSH development with a significantly reduced attack surface compared to running agents directly on the host.

---

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

jAilbox will discover or build your dev image, start the container, and open the project in VS Code or VSCodium via Remote SSH.

---

## Important: Project Image Requirements

Your development image **must** meet these requirements:

- **Do not** create or rely on a custom user. jAilbox always creates and runs as its own managed user called `jailbox` (with your host UID).
- Install all tools, language runtimes, and dependencies **globally** (system-wide) so they are available to the `jailbox` user.
- Include `bash` (preferred) or a working `/bin/sh`.
- Provide a supported package manager (`apt-get`, `apk`, `dnf`, or `yum`).

If your final stage is distroless or production-only, use `DEV_TARGET_STAGE` to target a proper development stage.

---

## Command Reference

```bash
jailbox              # Launch the environment (default)
jailbox doctor       # Check SSH and editor integration status
jailbox ssh-config   # Show SSH configuration instructions
jailbox --clean      # Remove container, volume, networks and jailbox runtime state
```

---

## Why not Dev Containers?

jAilbox is **not** a replacement for Microsoft's Dev Containers specification.

**Dev Containers** excel at team collaboration, standardized onboarding, and rich configuration through `devcontainer.json`.

**jAilbox** provides more **opinionated, hardened runtime defaults** focused on reducing risk when running untrusted code (particularly AI agents). It works with plain `Containerfile`/`Dockerfile` setups and adds optional egress control.

**Many teams use both**:
- Dev Containers for regular development and consistency
- jAilbox for AI-assisted coding sessions that benefit from stronger containment

---

## Configuration (`jailbox.conf`)

Optional `jailbox.conf` in project root:

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

When `EGRESS_ALLOW` is configured, jAilbox automatically adds the selected
editor's Remote SSH bootstrap hosts so the editor can install its remote server:

- `EDITOR=code`: `update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `main.vscode-cdn.net`, `vo.msecnd.net`
- `EDITOR=codium`: `github.com`, `githubusercontent.com`

**How egress enforcement works:** When `EGRESS_ALLOW` is set, jAilbox places the jailbox container on an internal-only Podman network — a network created with no external route and no DNS service. A tinyproxy sidecar is attached to both that internal network and a separate external-facing network, and acts as the sole outbound gateway at a fixed internal IP. Applications inside the jailbox container that ignore `HTTP_PROXY`/`HTTPS_PROXY` cannot reach the public internet directly: the internal network has no gateway, so outbound connections fail at the network level regardless of proxy cooperation. tinyproxy enforces the domain allowlist for all HTTP and HTTPS traffic that passes through it, and restricts HTTPS CONNECT tunnels to port 443.

Without `EGRESS_ALLOW`, the container runs on a standard Podman network with unrestricted outbound internet access.

---

## Security & Threat Model

### What jAilbox does well
- Read-only root filesystem
- Zero capabilities + no-new-privileges
- Rootless Podman containers (`--userns=keep-id`)
- Fresh SSH keypair per launch
- No container runtime sockets mounted
- Strict sshd configuration (key auth only, local forwarding only)
- Optional egress control: when `EGRESS_ALLOW` is set, the container is placed on an internal-only network with no direct external route and no DNS; an unprivileged tinyproxy sidecar is the only outbound gateway, accepts clients from the internal network only, and enforces the domain allowlist for HTTP/HTTPS

### Important realities
- The container runs with your **host UID**, so it can read and write your project files
- Project files are mounted writable. Selected paths like `.git/config`, `.github/workflows`, and `Containerfile` are mounted read-only over the writable project mount. The built-in list is illustrative, not exhaustive — anything the host or CI later executes (`Makefile`, `.envrc`, `package.json` scripts, editor task files, …) is writable unless you add it via `READONLY_EXTRA`, which extends the built-in set but can never remove from it. High-risk paths that are absent at launch (`.env`, `.github/workflows`, `.gitea/workflows`) are created as empty stubs so they can be mounted read-only; other absent paths — including `READONLY_EXTRA` entries, which produce a launch warning — are not protected.
- The AI (or any code running in the container) can still exfiltrate or destroy project contents
- You still share the kernel and container runtime trust boundary
- Without `EGRESS_ALLOW`, the container has unrestricted outbound internet access
- Host services listening on `0.0.0.0` (local dev servers, LLM runtimes, databases) remain reachable from the container through the Podman bridge gateway IP — even in egress mode, since the internal network's bridge interface still exists on the host. Bind sensitive host services to `127.0.0.1` if the container must not reach them
- Egress enforcement is proxy-mediated (HTTP/HTTPS domain filter), not packet-level: tinyproxy only filters traffic that passes through it and cannot inspect TLS payload; allowed endpoints can still receive exfiltrated data; this is not equivalent to a firewall, VM network isolation, or kernel-enforced packet filtering

jAilbox focuses on reducing accidental host exposure and limiting common container escape vectors, not defending against a determined kernel- or runtime-level attacker. It provides much better defaults than running agents directly on the host or in privileged containers, but it is **not** a full sandbox.

---

## How It Works

jAilbox follows a clean layered approach:

1. **Dev Image** — Uses or builds from your existing `Containerfile`/`Dockerfile`
2. **Wrapper Image** — Adds OpenSSH server, creates the managed `jailbox` user, and installs hardened sshd config
3. **Runtime** — Project mounted at `/home/jailbox/project` (writable) with selected paths overlaid read-only, plus a persistent home volume for the jailbox user
4. **SSH & Editor** — Generates project-specific SSH state under `~/.local/state/jailbox/projects/` and VS Code/VSCodium user profiles under `~/.local/state/jailbox/editor-profiles/`

## Repository Layout

```text
.
├── jailbox                  # Host-side CLI entrypoint
├── host/                    # Host orchestration modules sourced by jailbox
├── container/               # Files copied into wrapper/proxy images
│   ├── Containerfile.wrapper
│   ├── entrypoint.sh        # Wrapper container runtime entrypoint
│   ├── setup.sh             # Wrapper image setup script
│   ├── downloader-proxy-manager.sh
│   └── tinyproxy/
├── scripts/                 # Repository tooling
├── tests/                   # Unit, integration, and e2e tests
├── install.sh               # Installer for the jailbox bundle
└── README.md
```

The `host/` tree runs on the developer machine. The `container/` tree is copied
into images or executed inside containers. Repository maintenance commands stay
under `scripts/`, and test suites stay under `tests/`.

**What remains unavoidable** (due to Remote SSH limitations):
- An OpenSSH server is still required
- A generated SSH config is needed for dynamic ports and proxy settings
- jAilbox uses per-project editor profiles to avoid mutating your normal VS Code settings

**What jAilbox avoids**:
- Mutating host `~/.ssh/config`
- Mounting host `~/.gitconfig`; only `user.name` and `user.email` are copied into a generated config
- Mounting runtime sockets
- Dynamic sshd_config rewriting
- Overwriting `.vscode/settings.json`

---

## Requirements

- Linux with **Podman** (rootless preferred)
- `podman`, `ssh`, `ssh-keygen`
- VS Code or VSCodium with **Remote - SSH** extension

---

## Tested Configurations

Every release is gated on CI runs covering this matrix:

| Container OS | VS Code | VSCodium |
|---|---|---|
| Debian 12 (bookworm) | ✅ | ✅ |
| Alpine 3.21 | — | ✅ |
| Fedora 41 | ✅ | ✅ |

VS Code Remote SSH does not support Alpine SSH hosts; that combination is covered by VSCodium only.

---

## Project Status

jAilbox is usable today for real projects and is actively maintained, but still evolving.

**Repository**: https://github.com/francoisnt/jailbox

---

## License

MIT
