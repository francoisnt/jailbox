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
2. Builds a wrapper image with OpenSSH, editor prerequisites, and a managed
   `jailbox` user using your host UID.
3. Starts the hardened Podman container.
4. Writes per-project SSH runtime state under `.jailbox/`.
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
DEV_CONTAINERFILE=./Dockerfile
DEV_TARGET_STAGE=dev
EOF
```

Or use an existing image directly:

```bash
cat > jailbox.conf <<'EOF'
DEV_IMAGE=node:22-bookworm
EOF
```

Development images should install tools, language runtimes, and dependencies
system-wide, or otherwise make them available on `PATH` for all users. Do not
put required setup only in a username-specific home directory: jailbox creates
and uses its own managed user at runtime.

## What jailbox changes in your project

Jailbox keeps generated SSH runtime state in a project-local ignored directory
and never modifies your user-level `~/.ssh/config`, normal VS Code/VSCodium
user settings, or existing `.vscode/settings.json`.

```text
.jailbox/
  ssh_config
  key
  key.pub
  known_hosts
```

The `.jailbox/` directory is local generated state for one user and one
checkout. Jailbox ensures this entry exists in `.gitignore`:

```text
.jailbox/
```

Some editors resolve SSH hosts only through your default SSH config. If needed,
print the generated config path and host block:

```bash
jailbox ssh-config
```

Editor config that contains an absolute `.jailbox/ssh_config` path is
machine-local. Do not commit it unless your team explicitly wants checkout-local
editor configuration. Jailbox therefore keeps that setting in the generated
editor profile instead of mutating `.vscode/settings.json`.

The normal `code --remote` / `codium --remote` command does not pass OpenSSH
options through to Remote SSH resolution, so jailbox does not try to give the
editor `ssh -F`. For automatic launches, jailbox uses a generated editor
profile under
`${XDG_STATE_HOME:-$HOME/.local/state}/jailbox/editor-profiles/<project-hash>/`
and launches the editor with `--user-data-dir` so Remote SSH sees
`remote.SSH.configFile` before it resolves the host. This keeps VSCodium cache
files out of the project tree and does not touch your normal VS Code/VSCodium
user settings. Jailbox's own validation still uses:

```bash
ssh -F .jailbox/ssh_config <host> true
```

If Remote SSH still fails to resolve the generated host, manually set
`remote.SSH.configFile` to the absolute `.jailbox/ssh_config` path, or manually
include the project config from `~/.ssh/config`:

```sshconfig
Include /absolute/path/to/project/.jailbox/ssh_config
```

### SSH architecture

SSH is only the Remote SSH compatibility transport. Jailbox uses a static
container-side `sshd_config` and puts project-specific connection details in the
generated `.jailbox/ssh_config`: host alias, localhost port, key path,
known-hosts path, and any proxy `SetEnv` values required by `EGRESS_ALLOW`.

What remains unavoidable:

- An OpenSSH server is still required for VS Code/VSCodium Remote SSH.
- A generated SSH config is still required because the port, key, host alias,
  and optional proxy environment are checkout-local.
- The editor still needs `remote.SSH.configFile`; the `code --remote` /
  `codium --remote` CLI does not pass `ssh -F` through host resolution.

What jailbox avoids:

- No dynamic `sshd_config` rewriting at container startup.
- No server-side proxy `SetEnv` generation.
- No shell profile or `.bashrc` mutation.
- No automatic mutation of `.vscode/settings.json`.

Longer-term replacements could use a purpose-built editor transport, a Dev
Containers integration, or a non-editor `podman exec` workflow. Those would
reduce OpenSSH-specific requirements, but would no longer be plain Remote SSH.

Check the current project's integration state with:

```bash
jailbox doctor
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
- SSH sessions run as a jailbox-managed `jailbox` user with your host UID.
  jailbox creates this user when wrapping the dev image and fails if that
  username already exists with a different UID.
- Project files are mounted at `REMOTE_PATH` and remain writable except for
  protected metadata/build files listed below.
- `/home/jailbox` is a persistent Podman volume for the managed jailbox user.
- `/tmp` and `/run` are writable tmpfs mounts.
- SSH uses a fresh local Ed25519 keypair generated for each run.
- SSH forwarding is restricted to local port forwarding (`AllowTcpForwarding local`);
  remote forwarding, tunnel devices, and gateway ports are disabled.
- The container drops all Linux capabilities, disables new privileges, and
  applies CPU, memory, and PID limits.

## Configuration file

If present, `jailbox.conf` in the project root is loaded before launch.

The file is not shell and is never sourced. It uses one setting per line:

```text
KEY=value
KEY="value"
KEY='value'
```

Arrays use comma-separated values:

```text
EGRESS_ALLOW=github.com,api.github.com
```

Matching single or double quotes around a value are allowed and stripped.
Unknown keys, duplicate keys, spaces around `=`, command substitutions,
redirects, pipes, semicolons, mismatched or embedded quotes, and other
unsupported syntax are rejected.

Comments and blank lines are allowed.

## Supported `jailbox.conf` settings

### `DEV_IMAGE`

Use an existing image as the project dev image instead of building one.

```text
DEV_IMAGE=node:22-bookworm
```

Default: empty.

### `DEV_CONTAINERFILE`

Explicit container build file to use for the project dev image.

```text
DEV_CONTAINERFILE=./Dockerfile
```

If unset, jailbox discovers the first existing file in this order:

1. `Containerfile`
2. `Dockerfile`
3. `.devcontainer/Containerfile`
4. `.devcontainer/Dockerfile`

### `DEV_BUILD_CONTEXT`

Build context passed to `podman build`.

```text
DEV_BUILD_CONTEXT=.
```

Default: project root.

### `DEV_TARGET_STAGE`

Build a specific stage from a multi-stage container file.

```text
DEV_TARGET_STAGE=dev
```

Use this when the final stage is production/distroless and lacks a shell or
package manager.

### `EGRESS_ALLOW`

Array of allowed HTTP(S) hosts. If non-empty, jailbox starts a tinyproxy sidecar,
puts the jailbox container on an internal network, and writes proxy environment
variables into the generated SSH host config so Remote SSH sessions inherit
them explicitly.

```text
EGRESS_ALLOW=claude.ai,github.com,api.github.com
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

```text
REMOTE_PATH=/workspace/project
```

Default: `/home/jailbox/project`.

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

```text
DEV_IMAGE=node:22-bookworm
```

Use a dev stage from a multi-stage Dockerfile:

```text
DEV_CONTAINERFILE=./Dockerfile
DEV_TARGET_STAGE=dev
DEV_BUILD_CONTEXT=.
```

Restrict HTTP(S) egress:

```text
EGRESS_ALLOW=claude.ai,github.com,api.github.com
```
