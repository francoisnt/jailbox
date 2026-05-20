# jailbox

`jailbox` wraps a project's development image with SSH access and AI tooling,
then launches it as a hardened Podman container for AI-assisted development.

## Install

Download a release tarball, unpack it, and run the installer:

```bash
curl -fsSLO https://github.com/OWNER/jailbox/releases/download/v0.1.0/jailbox-v0.1.0.tar.gz
tar -xzf jailbox-v0.1.0.tar.gz
cd jailbox-v0.1.0
./install.sh
```

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

## Release

Maintainers can create and push a release tag with:

```bash
scripts/release.sh
```

The release script suggests a semantic version, asks for confirmation, creates
an annotated git tag, and pushes it to `origin`. Pushing a tag starts the GitHub
Actions release workflow, which builds `dist/jailbox-vX.Y.Z.tar.gz` from that
tagged checkout and uploads it to the GitHub Release.

Before `v1.0.0`, added or removed public API items suggest a minor bump, and
other changes suggest a patch bump. Use `--first-major` when the project is
ready for its first stable major release. After `v1.0.0`, removed config keys
or CLI flags suggest a major bump, added keys or flags suggest a minor bump, and
other changes suggest a patch bump.

Useful non-interactive forms:

```bash
scripts/release.sh --yes
scripts/release.sh --yes --dry-run
scripts/release.sh --first-major
```

To build the release tarball locally without publishing:

```bash
scripts/build-tarball.sh v0.2.0
```

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

## Security defaults

- The container root filesystem is always read-only (`--read-only`).
- Project files are mounted at `REMOTE_PATH` and remain writable except for
  protected metadata/build files listed below.
- `/home/devuser` is a persistent Podman volume.
- `/tmp` and `/run` are writable tmpfs mounts.
- SSH uses a fresh local Ed25519 keypair generated for each run.
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

### `AI_TOOLS`

Array of AI tools to install into the wrapper image.

```bash
AI_TOOLS=("claude" "aider")
```

Each tool must have a matching installer at `jailbox/install/<tool>.sh`.

Default:

```bash
AI_TOOLS=("claude")
```

### `EXTRA_PACKAGES`

Space-separated OS packages installed into the wrapper image.

```bash
EXTRA_PACKAGES="ripgrep jq make"
```

Package names must match the detected package manager in the dev image
(`apt-get`, `apk`, `dnf`, or `yum`).

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

### `CLAUDE_INSTALL_SHA256`

Optional expected SHA256 for the downloaded Claude installer script.

```bash
CLAUDE_INSTALL_SHA256="0123456789abcdef..."
```

If set, jailbox verifies the downloaded `https://claude.ai/install.sh` before
running it. If unset, jailbox prints a warning and the Claude install remains
unpinned.

### `AIDER_VERSION`

Optional exact `aider-chat` version.

```bash
AIDER_VERSION="0.86.1"
```

If set, jailbox installs `aider-chat==$AIDER_VERSION`. If unset, jailbox prints a
warning and installs the latest available `aider-chat`.

### `DEV_USER`

Username of the non-root user inside the container.

```bash
DEV_USER=appuser
```

Default: `devuser`. Set this when your project image already has a non-root user
under a different name (e.g. `ubuntu`, `app`, `node`). jailbox will SSH into the
container as this user and install AI tools under their account.

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
- `.ssh/config`
- `.ssh/jailbox_key`
- `.ssh/jailbox_key.pub`
- `.ssh/known_hosts`
- `jailbox`
- `jailbox.conf`

If `jailbox` itself lives inside the project, that subdirectory is also mounted
read-only.

## Example configs

Use a discovered local `Containerfile` and install Claude:

```bash
AI_TOOLS=("claude")
```

Use an existing Node image with Claude and Aider:

```bash
DEV_IMAGE="node:22-bookworm"
AI_TOOLS=("claude" "aider")
EXTRA_PACKAGES="ripgrep jq"
AIDER_VERSION="0.86.1"
```

Use a dev stage from a multi-stage Dockerfile:

```bash
DEV_CONTAINERFILE="./Dockerfile"
DEV_TARGET_STAGE="dev"
DEV_BUILD_CONTEXT="."
AI_TOOLS=("claude")
```

Restrict HTTP(S) egress:

```bash
AI_TOOLS=("claude")
EGRESS_ALLOW=("claude.ai" "github.com" "api.github.com")
```
