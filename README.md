# jAilbox

**Run coding agents in your project's development container with less access to your host.**

[![PR checks](https://github.com/francoisnt/jailbox/actions/workflows/pr-checks.yml/badge.svg)](https://github.com/francoisnt/jailbox/actions/workflows/pr-checks.yml)
[![Latest release](https://img.shields.io/github/v/release/francoisnt/jailbox)](https://github.com/francoisnt/jailbox/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

jailbox wraps your existing development image with SSH access and runs it in a
hardened Podman container. Open your project in VS Code or VSCodium and use its
terminal, tools, and coding agents inside the container.

- **Keep your toolchain.** Use your project's Containerfile/Dockerfile or a compatible development image.
- **Reduce host exposure.** A read-only container root, no Linux capabilities, no privilege escalation, and no container-engine sockets.
- **Choose access.** Protect or hide project paths and optionally restrict outbound HTTP(S) to allowed domains.
- **Keep your editor setup.** Separate per-project profiles leave your normal editor settings alone.

Building a script or orchestrator? The same executable provides an
[automation interface](docs/automation.md) to launch, inspect, connect to, and
clean up sandboxes without an editor.

[Quick start](#quick-start) · [Everyday use](#everyday-use) ·
[Development guide](docs/development.md) · [Automation guide](docs/automation.md) ·
[Security guide](docs/security.md)

## Quick start

### 1. Check requirements

You need Podman (rootless preferred), Bash 4.4+, OpenSSH client tools, GNU
coreutils or compatible utilities, and a SHA-256 utility. For the editor
workflow, install VS Code or VSCodium and its Remote SSH extension. Your project
needs a compatible development image or Containerfile/Dockerfile.
See [full requirements and setup](docs/development.md#requirements).

**Linux runs all integration tests. macOS currently has portable-test coverage
only; real container and editor behavior on Mac remains unverified.**
[Platform coverage](docs/development.md#tested-configurations) explains the limits.

### 2. Install

```bash
curl -fsSL https://github.com/francoisnt/jailbox/releases/latest/download/install.sh | bash
```

The installer comes from a published release and downloads the latest release
archive, checking its SHA-256 checksum before installation.

### 3. Launch your project

```bash
cd /path/to/your/project
jailbox init
jailbox
```

`init` creates a minimal `jailbox.conf` without overwriting an existing path.
jailbox builds or selects your development image, starts the container, and
opens the project through Remote SSH. Use the editor's integrated terminal to
run your tools inside the container. Subsequent launches reuse a compatible,
healthy sandbox.

No Containerfile? Add `DEV_IMAGE=node:22-bookworm` to `jailbox.conf` for a Node.js
development image, or select another [compatible image](docs/development.md#project-image-requirements).

**By default, the container can edit project files and access the internet.**
Read-only files are still readable. Configure the restrictions below before
launch when needed, and read the [security limits](#security-limits).

## Choose what the sandbox can access

Edit `jailbox.conf` to match your project. These examples use paths that must
already exist; choose the ones you need:

```conf
# Protect selected files from modification.
READONLY_PATHS=Makefile,scripts/deploy.sh

# Or restrict writes to selected directories; the rest becomes read-only.
WRITABLE_PATHS=src,build

# Hide existing files or directories inside the running container.
HIDDEN_PATHS=secrets

# Allow outbound HTTP(S) only to these domains (plus editor bootstrap hosts).
EGRESS_ALLOW=registry.npmjs.org,github.com
```

Add the domains your agent and tools require. Hiding files at runtime does not
exclude them from image builds: keep secrets outside the build context or use
container ignore files.

See the [configuration reference](docs/development.md#file-configuration-jailboxconf)
for defaults and examples, and the [security guide](docs/security.md) for path
precedence and network limits. After changing policy, stop the sandbox and
launch again.

## Everyday use

Run commands from the project's directory:

```bash
jailbox                 # Launch or reuse the sandbox and open the editor
jailbox --no-editor     # Launch from jailbox.conf without opening an editor
jailbox status          # Show resource inventory: running, stopped, or absent
jailbox stop            # Remove containers and networks; retain a persistent home
```

To rebuild after editing your Containerfile or to apply changed configuration:

```bash
jailbox stop
jailbox
```

Use your original launch command if you selected a custom configuration or
launched without an editor. Run lifecycle commands one at a time per project.
Stopping disconnects active sessions; if the next launch fails, fix the cause
and retry.

The home directory persists by default. `EPHEMERAL_HOME=true` makes the home
created for that container generation disposable on stop. **`jailbox --clean`
permanently deletes the project's home, runtime state, and derived images**
as well as its containers and networks. Host project files remain in place.
See [home retention and recovery](docs/development.md#everyday-use).

## Security limits

jailbox uses a read-only container root, drops all Linux capabilities, disables
privilege escalation, and mounts no Docker or Podman socket. SSH uses fresh
client and server keys per container generation and strict host-key checking.

Code can still change writable project files and send data to reachable
services. Network filtering is optional; allowed domains can receive data, and
host services listening on bridge-accessible addresses can remain reachable
even with filtering enabled. Containers rely on the Linux kernel and container
runtime for isolation. Persistent home contents remain sandbox-controlled.

Read the [security guide](docs/security.md) for the full protections, path rules,
and threat model.

## Guides and help

| Guide | What you will find |
|---|---|
| [Development](docs/development.md) | Configuration, images, editors, recipes, troubleshooting, and tested versions |
| [Automation](docs/automation.md) | Environment-driven core commands, scripts, connection records, lifecycle rules, and compatibility |
| [Security](docs/security.md) | File protections, hidden paths, network filtering, and their limits |
| [Comparison](docs/comparison.md) | Licensing, defaults, file access, networking, and alternatives |

For a launch or connection failure, start with the diagnostic and
[troubleshooting guide](docs/development.md#troubleshooting).
[Report a bug](https://github.com/francoisnt/jailbox/issues) with your jailbox
version, platform, and relevant diagnostics; omit credentials and secrets.

## Update or uninstall

Re-run the install command to update. It replaces the installed files without
touching project configuration, containers, or images.

Run `jailbox --uninstall` to remove the installation. Existing sandboxes remain;
if you want to remove them too, run `jailbox --clean` in each project beforehand.
See [uninstall details](docs/development.md#uninstalling), including the fallback
for macOS system Bash.

## License

jailbox is licensed under the [MIT License](LICENSE).
