# Development guide

[Home](../README.md) · [Development](development.md) · [Automation](automation.md) · [Security](security.md)

Use `jailbox.conf` to run your project in an editor or launch without opening one.
Start with the [quick start](../README.md#quick-start), then use this guide to
choose an image, configure access, and troubleshoot your session.

- [Requirements](#requirements)
- [Everyday use](#everyday-use)
- [Recipes](#recipes)
- [File configuration](#file-configuration-jailboxconf)
- [How it works](#how-it-works)
- [Project image requirements](#project-image-requirements)
- [Troubleshooting](#troubleshooting)
- [Tested configurations](#tested-configurations)

## Requirements

- **Linux or macOS** with **Podman** (rootless preferred)
- **Bash 4.4 or newer** (`brew install bash` on macOS)
- **GNU coreutils or compatible utilities**, including `realpath` with `-e`,
  `-m`, and `--relative-to`, and `sort -z`. Installation, launch, validation,
  and attachment check these capabilities and refuse with setup instructions
  if they are unavailable.
- `podman`, `ssh`, `ssh-keygen`, and either `sha256sum` or `shasum` (project
  identity is a SHA-256 hash of the project path). Filtered launches require
  an SSH client with `SetEnv` support (OpenSSH 7.8+).
- VS Code or VSCodium with the **Remote - SSH** extension (for the editor
  workflow)
- A project with a `Containerfile`/`Dockerfile` — or a compatible development
  image (see [Project image requirements](#project-image-requirements) and
  [Recipes](#recipes))

**macOS coverage is limited to portable tests; container and editor integration
on a Mac remain unverified.** Our hosted Mac CI runners cannot start the Linux VM
that Podman requires. See [Tested Configurations](#tested-configurations).

On macOS, install coreutils and put its commands first on `PATH` before installing
or running jailbox:

```bash
brew install bash coreutils
export PATH="$(brew --prefix bash)/bin:$(brew --prefix coreutils)/libexec/gnubin:$PATH"
```

Add that `export` line to your shell startup file to retain it in new terminals.
On Linux, install your distribution's `coreutils` package if it is missing.
The installer does not install system packages or edit shell startup files.

## Everyday use

Run these commands from your project directory:

```bash
jailbox                       # Launch or reuse the sandbox and open the editor
jailbox --no-editor           # Launch from the same file without opening an editor
jailbox --config PATH         # Use a selected configuration file and open the editor
jailbox --config jailbox.conf validate  # Check file configuration and local inputs
jailbox status               # Report resource inventory, not connection readiness
jailbox stop                 # Remove containers and networks; keep a persistent home
```

Run lifecycle commands one at a time for each project. Stopping or cleaning a
sandbox disconnects its editor and terminal sessions.

After changing configuration or updating jailbox, run `jailbox stop` followed
by your original launch command. Use the same sequence to rebuild after editing
your Containerfile: launching an existing sandbox alone does not rebuild it.
If the new launch fails, the previous sandbox is already gone; fix the cause
and launch again. Builds use local caches and do not guarantee fresh registry
images.

The home directory persists by default, including editor servers and installed
user tools. With `EPHEMERAL_HOME=true`, stop deletes the home created for that
container generation. Stop follows the policy recorded when the home was
created, not a later edit to the configuration file.

`jailbox --clean` permanently deletes the project's home, runtime state,
containers, networks, and derived images. Changing an existing persistent home
to ephemeral requires this full cleanup; changing ephemeral to persistent uses
stop followed by launch. Follow the diagnostic before deleting state.
See the [lifecycle reference](automation.md#lifecycle) for exact retention,
inspection, and recovery rules.

### Updating

Re-run the [install command](../README.md#quick-start) to get the latest published release. It cleanly replaces the previous install
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

Point jailbox at a [compatible development image](#project-image-requirements)
by adding one line to the generated config:

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

## File configuration (`jailbox.conf`)

Every file-driven launch requires a `jailbox.conf` in the project root. Create the minimal default safely with `jailbox init`:

```conf
# Additional project paths mounted read-only inside the sandbox.
READONLY_PATHS=
```

`init` refuses to overwrite any existing file or other filesystem object and
requires neither Podman nor an absent sandbox. It suggests existing `.env`,
`.git/hooks`, `.git/config`, `AGENTS.md`, `CLAUDE.md`, and `.github/workflows`
paths, in that order, as comments. Add chosen paths to the single comma-separated
`READONLY_PATHS=` assignment; suggestions do not enable protection themselves.
Protecting `.git/hooks` alone
does not prevent Git-triggered host execution: writable `.git/config` can select
other hooks or commands. Making `.git/config` read-only prevents in-sandbox
`git config --local` updates.

Configuration uses strict `KEY=value` lines (no shell syntax, values cannot
contain whitespace or ASCII control characters):

Use `jailbox --config PATH`, `jailbox --config PATH --no-editor`, or
`jailbox --config PATH validate` to select a complete config file. The option must
precede the command and is rejected for all other commands. The selected file
replaces rather than merges with the project config. Relative settings still
resolve from the project root. The default `jailbox.conf` is still required when
selecting an external file; it remains a persistent read-only anchor so a sandbox cannot
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
| `PIDS_LIMIT` | `256` | Development container process/thread limit (Podman `--pids-limit` value) |
| `EPHEMERAL_HOME` | `false` | Exact lowercase `true` or `false`; `true` makes the home belong to one container generation and deletes it on stop. Empty or other values are invalid. |
| `EDITOR` | `codium`, then `code` | Editor preference (`codium` or `code`); frontend-only, file-exclusive key |
| `EGRESS_ALLOW` | unset (unrestricted) | Comma-separated domain allowlist; enables egress control |
| `READONLY_PATHS` | — | Comma-separated existing project paths mounted read-only |
| `WRITABLE_PATHS` | — | Comma-separated existing project paths allowed to remain writable; non-empty makes the project base read-only |
| `HIDDEN_PATHS` | — | Comma-separated existing project files/directories whose contents are hidden at runtime |

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

`jailbox up` and `jailbox --no-editor` do not discover an editor or add bootstrap
hosts; its filtered sandbox contains only the configured allowlist. After an
explicit `jailbox stop`, a bare `jailbox` launch creates a sandbox whose policy
also permits the selected editor's hosts. Without `EGRESS_ALLOW`, both commands
use the ordinary unrestricted network and no allowlist is rendered.

See [network enforcement and its limits](security.md#network-enforcement).

## How It Works

jailbox follows a clean layered approach:

1. **Dev Image** — Uses or builds from your existing `Containerfile`/`Dockerfile`
2. **Wrapper Image** — Adds OpenSSH server, creates the managed `jailbox` user, and installs hardened sshd config
3. **Runtime** — Project mounted at `/home/jailbox/project` with the configured writable lanes and read-only protections, plus a home volume that is persistent by default
4. **SSH & Editor** — Generates project-specific SSH state under
   `~/.local/state/jailbox/projects/` and VS Code/VSCodium user profiles under
   `~/.local/state/jailbox/editor-profiles/`. Both use `XDG_STATE_HOME` instead
   of `~/.local/state` when set. Unset or empty uses the default; relative paths
   are rejected.

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

- Existing image users (such as `node`) are preserved. jailbox creates its own
  `jailbox` user and group with unused IDs and maps your host identity to them.
  Do not pre-create a `jailbox` user or group or require tools from another
  user's private home.
- Install all tools, language runtimes, and dependencies **globally**
  (system-wide) so they are available to the `jailbox` user.
- Include `bash` (preferred) or a working `/bin/sh`.
- Provide a supported package manager (`apt-get`, `apk`, `dnf`, or `yum`).
- The installed OpenSSH server must support `SetEnv` (introduced in OpenSSH
  7.8). Wrapper builds check this feature and report an error if unavailable.
  Proxy delivery does not require the newer server `Include` directive.

If your final stage is distroless or production-only, use `DEV_TARGET_STAGE`
to target a proper development stage.

## Troubleshooting

Follow the failing command’s diagnostic and recovery guidance.
`jailbox --config jailbox.conf validate` checks file configuration and local launch inputs; `status`
reports inventory, and `ssh-config` prints human connection instructions. None
of these certifies attachment health.

| Symptom | Cause / fix |
|---|---|
| `no Containerfile found` | Set `DEV_IMAGE=<image>` or `DEV_CONTAINERFILE=<path>` in `jailbox.conf` |
| `dev image has no usable shell` / `no supported package manager` | The selected image/stage is production or distroless; set `DEV_TARGET_STAGE` to a dev stage or use `DEV_IMAGE` |
| `managed user 'jailbox' already exists in the dev image` | Remove/rename that user in the dev image; jailbox manages its own user |
| `managed group 'jailbox' already exists in the dev image` | Use a dev image without that reserved group; existing users with other names are preserved |
| `refusing sandbox reuse` | Follow the stated recovery; `stop` preserves persistent homes and deletes ephemeral homes, while `--clean` permanently deletes home/runtime state |
| `sandbox convergence failed` | Startup or synchronization began before failure; read the cleanup and retained-resource report before retrying or performing recovery |
| `local port N is already in use` | Another process holds the project's derived SSH port; stop it and relaunch |
| `SSH generation is orphaned` | Credentials outlived their container; run `jailbox stop` (which removes them) then your original launch command |
| `SSH state path ... is a symlink` / `is not a directory` | jailbox will not read or delete credentials through a substituted path; replace that path with a real directory, or point `XDG_STATE_HOME` at one, then relaunch |
| A request from inside the container fails in egress mode | Check the proxy log: `podman logs <project>-proxy` (find the name with `podman ps`). Blocked hosts appear as `Proxying refused on filtered domain` — add the domain to `EGRESS_ALLOW`, then use `jailbox stop` followed by your original launch command |
| VS Code cannot connect to an Alpine-based container | VS Code Remote SSH does not support Alpine hosts; set `EDITOR=codium` |
| Editor preflight reports missing binary or Remote SSH extension | Install the named requirement; select `EDITOR=codium` or `EDITOR=code` in `jailbox.conf` |
| `sshd did not become ready in time` | Inspect the container log: `podman logs <container-name>` (printed in the error) |
| Editor shows `Unable to watch for file changes` | The Linux kernel running the container has a low `fs.inotify.max_user_watches` limit (jailbox warns below 524288). On the Linux host running Podman — or inside its VM on macOS — raise it persistently: `echo 'fs.inotify.max_user_watches=524288' \| sudo tee /etc/sysctl.d/60-jailbox-inotify.conf` then `sudo sysctl --system`. On macOS, first enter the VM with `podman machine ssh` and run those commands there. Reapply the setting if you remove and recreate the VM. |

## Tested Configurations

CI runs portable tests on Linux and macOS: shell and CLI contracts, configuration,
packaging, and installation. These tests use simulated engine/transport behavior
where needed; they do not start a real Podman container or attach a real editor.
The runtime, lifecycle matrix, and editor gates run on Linux hosts only. The
container OS/editor combinations below describe that Linux-host coverage.

The limitation comes from the available CI infrastructure. Linux hosts can run
Podman containers directly; macOS needs Podman Machine to start a Linux virtual
machine first. GitHub's hosted ARM Mac runners are themselves virtual machines,
and [they cannot start another VM inside them (nested virtualization)](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#limitations-for-arm64-macos-runners).
Our current CI setup therefore cannot exercise the real Mac container workflow.
We do not use Intel runners as a workaround: they would require older Podman
versions because [Podman 6 removed Intel Mac support](https://github.com/podman-container-tools/podman/releases/tag/v6.0.0),
and would still leave current Apple Silicon behavior untested. We do not yet
have a dedicated Apple Silicon runtime CI host.

No verified Apple Silicon runtime result is recorded here. VM startup, shared
file ownership and protected mounts, SSH forwarding, egress filtering, home
retention, and actual editor attachment on macOS remain unverified. Passing
portable tests or Linux runtime tests does not establish those Mac behaviors.
Closing this gap requires a Mac host that can run Podman Machine, with recorded
test results for the relevant macOS, architecture, Podman, image, and editor versions.

<!-- BEGIN GENERATED: tested-matrix -->
<!-- Generated by scripts/gen-tested-matrix.sh from versions.env. Edit those, then run: bash scripts/gen-tested-matrix.sh --write -->

The release gate installs the exact versions pinned in
[`versions.env`](https://github.com/francoisnt/jailbox/blob/master/versions.env) — editors, Remote SSH extensions, the
VSCodium REH server, and container base images — so a green gate vouches for
this specific matrix. A daily canary workflow tests every new upstream
release against the full suite and advances the pins automatically when it
passes; failures are tracked as `canary`-labeled issues. Alpine/VSCodium is
a best-effort tier: the pinned combination is release-blocking, while
latest-version failures only file issues.

| Container OS | VS Code 1.140.0 | VSCodium 1.135.06055 |
|---|---|---|
| Debian 12 | ✅ | ✅ |
| Alpine 3.21 | — | ✅ |
| Fedora 41 | ✅ | ✅ |

VS Code Remote SSH does not support Alpine SSH hosts; that combination is
covered by VSCodium only.

Remote extensions: `ms-vscode-remote.remote-ssh` 0.128.0
(VS Code), `jeanp413.open-remote-ssh` 0.3.1 (VSCodium).
VSCodium REH server: 1.135.06055 (commit `1a46a584725d5dd330e0bcd7f5510f24990efcf2`).

Last verified: 2026-10-04
<!-- END GENERATED: tested-matrix -->

Successful full test runs are listed in the
[master history](https://github.com/francoisnt/jailbox/blob/master/compatibility/master.csv)
and [release history](https://github.com/francoisnt/jailbox/blob/master/compatibility/releases.csv).
Each row identifies the tested commit, editor/extension versions, VSCodium server
commit, development image tags, and the Bash/Podman versions observed by the Linux
runtime gate.
These are historical results, not proof for other mixtures or today's master.
macOS coverage remains portable only.
