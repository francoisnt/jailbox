# jailbox

`jailbox` wraps a project's development image with SSH access, then launches it
as a hardened Podman container for AI-assisted development.

It is designed for projects that already have, or can build, a development
container image. jailbox adds the editor/SSH layer around that image without
mounting container runtime sockets into the AI environment. The project image
owns any AI tools the team wants to provide.

## Requirements

`jailbox` is currently Linux-first. Installation uses ordinary Unix shell
tools, but running jailbox requires Linux container behavior from Podman.

Required host tools:

- `podman`
- `ssh`
- `ssh-keygen`
- `cksum`
- `realpath`
- VSCodium or VS Code with the Remote SSH extension and a `codium` or `code`
  CLI in `PATH`

macOS may work with Podman Machine, but it is not currently a tested runtime
target.

## Install

Download a release tarball, unpack it, and run the installer:

```bash
curl -fsSLO https://github.com/francoisnt/jailbox/releases/download/v0.1.0/jailbox-v0.1.0.tar.gz
tar -xzf jailbox-v0.1.0.tar.gz
cd jailbox-v0.1.0
./install.sh
```

First release tarball:
[francoisnt/jailbox](https://github.com/francoisnt/jailbox/releases/download/v0.1.0/jailbox-v0.1.0.tar.gz)

By default, this installs jailbox assets to:

```text
~/.local/share/jailbox
```

and creates this command symlink:

```text
~/.local/bin/jailbox
```

Make sure `~/.local/bin` is in your `PATH`.

To install somewhere else:

```bash
PREFIX="$HOME/.local" ./install.sh
```

or set exact locations:

```bash
JAILBOX_INSTALL_DIR="$HOME/tools/jailbox" JAILBOX_BIN_DIR="$HOME/bin" ./install.sh
```

To uninstall:

```bash
./install.sh --uninstall
```

## Quick start

Run `jailbox` from the root of a project that has one of these files:

- `Containerfile`
- `Dockerfile`
- `.devcontainer/Containerfile`
- `.devcontainer/Dockerfile`

```bash
cd /path/to/project
jailbox
```

On first launch, jailbox:

1. Builds or selects the project development image.
2. Builds a wrapper image with OpenSSH and editor prerequisites.
3. Starts the hardened Podman container.
4. Writes per-project SSH runtime state under your XDG state directory.
5. Opens the project through VS Code or VSCodium Remote SSH.

To remove the container, proxy sidecar, network, SSH runtime state, and
persistent home volume for the current project:

```bash
jailbox --clean
```

If the final stage of your Dockerfile is production-only or distroless, point
jailbox at a development stage:

```bash
cat > jailbox.conf <<'EOF'
DEV_CONTAINERFILE="./Dockerfile"
DEV_TARGET_STAGE="dev"
EOF
```

Or use an existing image directly:

```bash
cat > jailbox.conf <<'EOF'
DEV_IMAGE="node:22-bookworm"
EOF
```

## What jailbox changes in your project

Each project gets generated SSH runtime state under
`${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/<project-hash>/`. Jailbox does
not create SSH runtime files inside the project tree and does not modify your
user-level `~/.ssh/config`.

Some editors resolve SSH hosts only through your default SSH config. If needed,
print the generated config path and host block:

```bash
jailbox ssh-config
```

Then add the generated config manually to `~/.ssh/config`:

```sshconfig
Include ~/.local/state/jailbox/<project-hash>/ssh_config
```

Other generated state:

- Podman image, container, volume, and network names derived from a hash of the
  full project path

Project files remain mounted writable inside the container at `REMOTE_PATH`.
Selected metadata, workflow, and jailbox files are mounted read-only over that
writable project mount.

## Release

Maintainers can create and push a release tag with `scripts/release.sh`.

The release script suggests a semantic version, asks for confirmation, creates
an annotated git tag, and pushes it to `origin`. Pushing a tag starts the GitHub
Actions release workflow, which builds `dist/jailbox-vX.Y.Z.tar.gz` from that
tagged checkout and uploads it to the GitHub Release.

Before `v1.0.0`, added or removed public API items suggest a minor bump, and
other changes suggest a patch bump. Use `--first-major` when the project is
ready for its first stable major release. After `v1.0.0`, removed config keys
or CLI flags suggest a major bump, added keys or flags suggest a minor bump, and
other changes suggest a patch bump.

Useful forms:

```bash
scripts/release.sh
scripts/release.sh --yes
scripts/release.sh --yes --dry-run
scripts/release.sh --first-major
scripts/build-tarball.sh v0.2.0
```

## Security defaults

- The container root filesystem is always read-only (`--read-only`).
- Project files are mounted at `REMOTE_PATH` and remain writable except for
  protected metadata/build files listed below.
- `/home/$DEV_USER` is a persistent Podman volume.
- `/tmp` and `/run` are writable tmpfs mounts.
- SSH uses a fresh local Ed25519 keypair generated for each run.
- SSH forwarding is restricted to local port forwarding (`AllowTcpForwarding local`);
  remote forwarding, tunnel devices, and gateway ports are disabled.
- The container drops all Linux capabilities except a minimal set required for
  OpenSSH privilege separation and user session switching, disables new
  privileges, and applies CPU, memory, and PID limits.

## Configuration file

If present, `jailbox.conf` in the project root is loaded before launch.

The file uses simple Bash assignment syntax, but jailbox validates every
non-comment line against an allowlist before sourcing it. Arbitrary shell code,
unknown keys, command substitutions, redirects, pipes, semicolons, and other
unsupported syntax are rejected.

Comments and blank lines are allowed.

## Supported `jailbox.conf` settings

### `DEV_IMAGE`

Use an existing image as the project dev image instead of building one.

```bash
DEV_IMAGE="node:22-bookworm"
```

Default: empty.

### `DEV_CONTAINERFILE`

Explicit container build file to use for the project dev image.

```bash
DEV_CONTAINERFILE="./Dockerfile"
```

If unset, jailbox discovers the first existing file in this order:

1. `Containerfile`
2. `Dockerfile`
3. `.devcontainer/Containerfile`
4. `.devcontainer/Dockerfile`

### `DEV_BUILD_CONTEXT`

Build context passed to `podman build`.

```bash
DEV_BUILD_CONTEXT="."
```

Default: project root.

### `DEV_TARGET_STAGE`

Build a specific stage from a multi-stage container file.

```bash
DEV_TARGET_STAGE="dev"
```

Use this when the final stage is production/distroless and lacks a shell or
package manager.

### `EGRESS_ALLOW`

Array of allowed HTTP(S) hosts. If non-empty, jailbox starts a tinyproxy sidecar,
puts the jailbox container on an internal network, and exports proxy environment
variables into the jailbox container.

```bash
EGRESS_ALLOW=("claude.ai" "github.com" "api.github.com")
```

Entries must be plain hostnames, not URLs, wildcards, or regexes. Each entry
allows the exact hostname and its subdomains.

Default: empty, which means normal outbound network access.

Direct egress is blocked by the internal Podman network. Outbound HTTP(S) is
brokered through a tinyproxy sidecar. The remaining limitation is that
enforcement depends on the proxy's protocol/domain filtering, not on per-packet
domain-aware firewalling.

Enforcement model: enforced at the network-route layer for direct egress;
allowlist enforcement is proxy-mediated and limited to HTTP(S).

Not protected against:

- Malicious proxy bypasses if tinyproxy has a bug.
- DNS/CDN/IP drift ambiguity (domain A records can change; IP-based connections
  bypass the allowlist entirely).
- Non-HTTP protocols unless blocked by lack of routing.
- Traffic to services reachable on the internal Podman network.

### `REMOTE_PATH`

Container path where the project is mounted and opened in the editor.

```bash
REMOTE_PATH="/workspace/project"
```

Default: `/home/$DEV_USER/project` (tracks `DEV_USER` automatically).

### `DEV_USER`

Username of the non-root user inside the container.

```bash
DEV_USER=appuser
```

Default: `devuser`. Set this when your project image already has a non-root user
under a different name (e.g. `ubuntu`, `app`, `node`). jailbox will SSH into the
container as this user.

`REMOTE_PATH` defaults to `/home/$DEV_USER/project` and tracks `DEV_USER`
automatically, so no extra update is needed when you change `DEV_USER`.

## Protected read-only project paths

When present, these paths are mounted read-only over the writable project mount:

- `Containerfile`
- `Dockerfile`
- `.devcontainer/Containerfile`
- `.devcontainer/Dockerfile`
- `.git/config`
- `.git/config.lock`
- `.git/hooks`
- `.gitignore`
- `.gitmodules`
- `.env`
- `.gitea/workflows`
- `.github/workflows`
- `.jailbox`
- `jailbox`
- `jailbox.conf`

If `jailbox` itself lives inside the project, that subdirectory is also mounted
read-only.

## Example configs

Use a discovered local `Containerfile`:

No `jailbox.conf` is required.

Use an existing Node image:

```bash
DEV_IMAGE="node:22-bookworm"
```

Use a dev stage from a multi-stage Dockerfile:

```bash
DEV_CONTAINERFILE="./Dockerfile"
DEV_TARGET_STAGE="dev"
DEV_BUILD_CONTEXT="."
```

Restrict HTTP(S) egress:

```bash
EGRESS_ALLOW=("claude.ai" "github.com" "api.github.com")
```
